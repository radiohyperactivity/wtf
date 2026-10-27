import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';

/// Deletes a location or class and everything below it, like
/// `wtf location delete --recursive`: the server's preview says what would
/// go, the dialog shows it, and stock or items in it are only deleted when
/// that is ticked (--force). Everything happens in one transaction on the
/// server. True when deleted.
Future<bool> deleteNode(
  BuildContext context,
  TreeKind kind,
  String id,
  String path,
) async {
  final client = context.read<Session>().client;
  final locations = kind == TreeKind.locations;
  final noun = locations ? 'location' : 'class';
  final Deletion preview;
  try {
    preview = locations
        ? await client.locationDeletion(id)
        : await client.classDeletion(id);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final below = preview.nodes.length - 1;
  final uses = preview.useCount;
  var force = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final scheme = Theme.of(context).colorScheme;
        final usesText = locations
            ? '$uses stock ${uses == 1 ? 'row is' : 'rows are'} in ${below > 0 ? 'them' : 'it'}:'
            : '$uses ${uses == 1 ? 'item is' : 'items are'} in ${below > 0 ? 'them' : 'it'}'
                  '${preview.stock > 0 ? ', with ${preview.stock} stock ${preview.stock == 1 ? 'row' : 'rows'}' : ''}:';
        return AlertDialog(
          title: Text('Delete $noun $path?'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (below > 0) ...[
                  Text(
                    'And the $below ${below == 1 ? noun : (locations ? 'locations' : 'classes')} below it:',
                  ),
                  for (final p in preview.nodes.reversed.skip(1).take(50))
                    Text('  $p'),
                  if (below > 50) Text('  … and ${below - 50} more'),
                  const SizedBox(height: 12),
                ],
                if (uses > 0) ...[
                  Text(usesText),
                  for (final u in preview.uses.take(50)) Text('  $u'),
                  if (uses > 50) Text('  … and ${uses - 50} more'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: force,
                    onChanged: (v) => setState(() => force = v ?? false),
                    title: Text(
                      locations
                          ? 'Delete that stock too'
                          : 'Delete those items too, with their stock',
                    ),
                  ),
                ],
                if (below == 0 && uses == 0)
                  const Text('Nothing else is in it.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: uses > 0 && !force
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    final recursive = below > 0 || uses > 0;
    if (locations) {
      await client.deleteLocation(id, recursive: recursive, force: force);
    } else {
      await client.deleteClass(id, recursive: recursive, force: force);
    }
    if (context.mounted) showMessage(context, 'Deleted $path.');
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}
