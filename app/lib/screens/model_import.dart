// Importing model files: attributes and classes set up for one use
// (seed/model-format.md), from the class tree or below a class.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/common.dart';
import 'attribute_screens.dart' show UnitFile;

/// Lets the user choose a model file; null when cancelled. Tests replace it.
Future<UnitFile?> Function() pickModelFile = () async {
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

/// Imports a model file, like `wtf model import`: a dry run first, which
/// shows what would be added, how much is there already and any conflicts;
/// then, when asked, the import. Its classes go below the class [parentId]
/// (whose path is [parentPath]), or at the top.
Future<void> importModelFile(
  BuildContext context, {
  String? parentId,
  String? parentPath,
}) async {
  final client = context.read<Session>().client;
  final UnitFile? file;
  try {
    file = await pickModelFile();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (file == null || !context.mounted) return;
  String title = file.name;
  try {
    final named = (jsonDecode(file.text) as Map)['name'];
    if (named is String && named.trim().isNotEmpty) {
      title = '${named.trim()} (${file.name})';
    }
  } on Object {
    showError(context, InputError('${file.name} is not JSON.'));
    return;
  }
  final ModelImport preview;
  try {
    preview = await client.importModel(
      file.text,
      parent: parentId,
      dryRun: true,
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) =>
        ModelImportDialog(title: title, below: parentPath, report: preview),
  );
  if (go != true || !context.mounted) return;
  try {
    final done = await client.importModel(file.text, parent: parentId);
    if (!context.mounted) return;
    if (!done.applied) {
      // Something changed since the dry run.
      await showDialog<void>(
        context: context,
        builder: (context) =>
            ModelImportDialog(title: title, below: parentPath, report: done),
      );
      return;
    }
    showMessage(
      context,
      'Imported ${_count(done.classes.length, 'class', 'classes')} and '
      '${_count(done.attributes.length, 'attribute')}.',
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

String _count(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// What a model import would add (or the conflicts that stop it), with
/// Import when there is something to import and nothing in the way.
class ModelImportDialog extends StatelessWidget {
  const ModelImportDialog({
    super.key,
    required this.title,
    required this.report,
    this.below,
  });

  final String title;
  final ModelImport report;

  /// The path of the class the classes go below; null: at the top.
  final String? below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = report;
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
    return AlertDialog(
      title: Text('Import $title'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                below == null
                    ? 'Its classes go at the top of the class tree.'
                    : 'Its classes go below $below.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
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
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            blocked || r.nothingNew || r.applied ? 'Close' : 'Cancel',
          ),
        ),
        if (!blocked && !r.nothingNew && !r.applied)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import'),
          ),
      ],
    );
  }
}
