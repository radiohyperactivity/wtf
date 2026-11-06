// Model files (seed/model-format.md): classes with their attributes, set
// up for one use, for admins. Importing one, from Admin; exporting a class with
// everything below it, from Admin or the class's menu.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/input.dart';
import '../session.dart';
import '../widgets/files.dart' show saveDownloadedFile;
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

/// Imports a model file, like `wtf model import`, from Admin → Import: a
/// dry run first, which shows what would be added and how much is there
/// already, or why it can't be imported; then, when asked, the import. A
/// file with classes puts them at the top of the class tree, or below a
/// class chosen in the preview. True when something was imported.
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
    if (context.mounted) showMessage(context, 'Imported ${_imported(done)}.');
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// What an import added, briefly: "2 classes and 3 attributes".
String _imported(ModelImport r) {
  final parts = [
    if (r.classesAdded > 0) count(r.classesAdded, 'class', 'classes'),
    if (r.attributesAdded > 0) count(r.attributesAdded, 'attribute'),
  ];
  return parts.isEmpty ? 'nothing new' : parts.join(' and ');
}

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

/// What a model import would add, with Import when there is something to
/// import. For a file with classes it says where they go, and Change…
/// chooses another class: the dry run is then done again, since what is
/// there already depends on it, and may be refused there. Pops with where
/// the classes go when Import is pressed.
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
    final offered = !r.nothingNew;
    final one = r.classesExisting + r.attributesExisting == 1;
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
                    TextButton(
                      onPressed: _busy ? null : _change,
                      child: const Text('Change…'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (r.nothingNew)
                const Text('Everything in this file is there already.')
              else ...[
                const Text('This adds:'),
                if (r.classesAdded > 0)
                  line('Classes', count(r.classesAdded, 'class', 'classes')),
                if (r.attributesAdded > 0)
                  line('Attributes', count(r.attributesAdded, 'attribute')),
                if (r.items > 0 || r.stock > 0)
                  line(
                    'Defaults',
                    'given to ${[if (r.items > 0) count(r.items, 'item'), if (r.stock > 0) count(r.stock, 'stock row')].join(' and ')} '
                        'already there',
                  ),
              ],
              if (r.classesExisting + r.attributesExisting > 0 && !r.nothingNew)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${[if (r.classesExisting > 0) count(r.classesExisting, 'class', 'classes'), if (r.attributesExisting > 0) count(r.attributesExisting, 'attribute')].join(' and ')} '
                    'in the file ${one ? 'is' : 'are'} there already, and '
                    '${one ? 'is' : 'are'} used as ${one ? 'it is' : 'they are'}.',
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
