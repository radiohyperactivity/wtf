// Model files (seed/model-format.md): units, attributes and classes set up
// for one use, for admins. Importing one, from Admin; exporting a class with
// everything below it, from Admin or the class's menu.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/attachments.dart' show saveDownloadedFile;
import '../widgets/common.dart';
import '../widgets/pickers.dart';

/// A model file chosen to import: its file name and its text.
typedef ModelFile = ({String name, String text});

/// Lets the user choose a model file; null when cancelled. Tests replace it.
Future<ModelFile?> Function() pickModelFile = () async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choose a model file',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (files.isEmpty) return null;
  final bytes = await files.first.readAsBytes();
  return (
    name: files.first.name,
    text: utf8.decode(bytes, allowMalformed: true),
  );
};

/// The class a file's classes go below: its id and path; id null for the
/// top of the class tree.
typedef ImportBelow = ({String? id, String path});

const ImportBelow _top = (id: null, path: '');

/// Imports a model file, like `wtf model import`, from Manage → Import: a
/// dry run first, which shows what would be added, how much is there
/// already and any conflicts; then, when asked, the import. A file with
/// classes puts them at the top of the class tree, or below a class chosen
/// in the preview. True when something was imported.
Future<bool> importModelFile(BuildContext context) async {
  final client = context.read<Session>().client;
  final ModelFile? file;
  try {
    file = await pickModelFile();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (file == null || !context.mounted) return false;
  final text = file.text;
  String title = file.name;
  final bool hasClasses;
  try {
    final json = jsonDecode(text) as Map;
    final meta = json['meta'];
    if (meta is Map &&
        meta['name'] is String &&
        (meta['name'] as String).trim().isNotEmpty) {
      title = '${(meta['name'] as String).trim()} (${file.name})';
    }
    hasClasses =
        json['classes'] is List && (json['classes'] as List).isNotEmpty;
  } on Object {
    showError(context, InputError('${file.name} is not JSON.'));
    return false;
  }
  final ModelImport preview;
  try {
    preview = await client.importModel(text, dryRun: true);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final below = await showDialog<ImportBelow>(
    context: context,
    builder: (context) => ModelImportDialog(
      title: title,
      file: text,
      hasClasses: hasClasses,
      report: preview,
    ),
  );
  if (below == null || !context.mounted) return false;
  try {
    final done = await client.importModel(text, parent: below.id);
    if (!context.mounted) return done.applied;
    if (!done.applied) {
      // Something changed since the dry run.
      await showDialog<void>(
        context: context,
        builder: (context) => ModelImportDialog(
          title: title,
          file: text,
          hasClasses: hasClasses,
          report: done,
          below: below,
        ),
      );
      return false;
    }
    showMessage(context, 'Imported ${_imported(done)}.');
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// What an import added, briefly: "2 classes and 3 attributes".
String _imported(ModelImport r) {
  final parts = [
    if (r.classes.isNotEmpty) _count(r.classes.length, 'class', 'classes'),
    if (r.attributes.isNotEmpty) _count(r.attributes.length, 'attribute'),
    if (r.units.isNotEmpty) _count(r.units.length, 'unit'),
    if (r.classes.isEmpty && r.attributes.isEmpty && r.units.isEmpty)
      'what was new',
  ];
  return parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

String _count(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// Admin → Export: asks which class, then exports it as [exportModelFile]
/// does.
Future<void> exportChosenClass(BuildContext context) async {
  final client = context.read<Session>().client;
  final id = await pickNode(
    context,
    TreeKind.classes,
    title: 'Export which class?',
  );
  if (id == null || !context.mounted) return;
  try {
    final name = (await client.tree(TreeKind.classes))[id]?.name ?? 'model';
    if (context.mounted) await exportModelFile(context, id, name);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Exports the class [classId], named [name], with everything below it as a
/// model file, like `wtf model export`, and saves it as "[name].json".
Future<void> exportModelFile(
  BuildContext context,
  String classId,
  String name,
) async {
  final client = context.read<Session>().client;
  try {
    final file = await client.exportModel(classId);
    final fileName = '${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.json';
    await saveDownloadedFile(fileName, utf8.encode(file));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// What a model import would add (or the conflicts that stop it), with
/// Import when there is something to import and nothing in the way. For a
/// file with classes it says where they go, and Change… chooses another
/// class: the dry run is then done again, since what is there already
/// depends on it. Pops with where the classes go when Import is pressed.
class ModelImportDialog extends StatefulWidget {
  const ModelImportDialog({
    super.key,
    required this.title,
    required this.file,
    required this.hasClasses,
    required this.report,
    this.below = _top,
  });

  final String title;

  /// The file's text, for the dry runs.
  final String file;
  final bool hasClasses;

  /// The dry run (or the import) for [below].
  final ModelImport report;
  final ImportBelow below;

  @override
  State<ModelImportDialog> createState() => _ModelImportDialogState();
}

class _ModelImportDialogState extends State<ModelImportDialog> {
  late ModelImport _report = widget.report;
  late ImportBelow _below = widget.below;
  bool _busy = false;

  Future<void> _change() async {
    final client = context.read<Session>().client;
    final id = await pickNode(
      context,
      TreeKind.classes,
      title: 'Import the classes below',
      allowTopLevel: true,
    );
    if (id == null || !mounted) return;
    final ImportBelow below = id == topLevel
        ? _top
        : (id: id, path: (await client.tree(TreeKind.classes)).pathOf(id));
    if (below.id == _below.id || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await client.importModel(
        widget.file,
        parent: below.id,
        dryRun: true,
      );
      if (mounted) {
        setState(() {
          _report = report;
          _below = below;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _report;
    Widget line(String label, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: text),
          ],
        ),
      ),
    );
    final blocked = r.conflicts.isNotEmpty;
    final offered = !blocked && !r.nothingNew && !r.applied;
    return AlertDialog(
      title: Text('Import ${widget.title}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.hasClasses) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _below.id == null
                            ? 'Its classes go at the top of the class tree.'
                            : 'Its classes go below ${_below.path}.',
                      ),
                    ),
                    if (!r.applied)
                      TextButton(
                        onPressed: _busy ? null : _change,
                        child: const Text('Change…'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (blocked) ...[
                Text(
                  'Nothing can be imported until these are fixed in the file:',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                for (final (where, message) in r.conflicts)
                  line(where, message),
                const SizedBox(height: 16),
              ],
              if (r.nothingNew)
                const Text('Everything in this file is there already.')
              else ...[
                Text(blocked ? 'It would add:' : 'This adds:'),
                if (r.quantities.isNotEmpty)
                  line('Quantities', r.quantities.join(', ')),
                if (r.families.isNotEmpty)
                  line('Unit families', r.families.join(', ')),
                if (r.units.isNotEmpty) line('Units', r.units.join(', ')),
                if (r.attributes.isNotEmpty)
                  line('Attributes', r.attributes.join(', ')),
                if (r.options.isNotEmpty) line('Options', r.options.join(', ')),
                if (r.classes.isNotEmpty) line('Classes', r.classes.join(', ')),
                if (r.assignments.isNotEmpty)
                  line('Assignments', r.assignments.join(', ')),
              ],
              if (r.existing > 0 && !r.nothingNew)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${_count(r.existing, 'thing')} in the file '
                    '${r.existing == 1 ? 'is' : 'are'} there already, and '
                    '${r.existing == 1 ? 'is' : 'are'} used as '
                    '${r.existing == 1 ? 'it is' : 'they are'}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(offered ? 'Cancel' : 'Close'),
        ),
        if (offered)
          FilledButton(
            onPressed: _busy ? null : () => Navigator.pop(context, _below),
            child: const Text('Import'),
          ),
      ],
    );
  }
}
