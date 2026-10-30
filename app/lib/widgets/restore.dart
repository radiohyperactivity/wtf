// Deleted objects: the banner on their screen, and restoring them (see
// api/deleting.md). A restore brings back what was deleted together with
// the object; when it is in something deleted, the app asks whether to
// restore that too or to put it somewhere else, as the CLI does.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import 'common.dart';
import 'pickers.dart';

/// The kinds of objects the app restores.
enum RestoreKind {
  item('items', 'item', 'class', TreeKind.classes),
  stock('stock', 'stock row', 'location', TreeKind.locations),
  location('locations', 'location', 'parent', TreeKind.locations),
  cls('classes', 'class', 'parent', TreeKind.classes),
  attribute('attributes', 'attribute', null, null);

  const RestoreKind(this.historyKind, this.noun, this.place, this.tree);

  /// As in the API's history routes.
  final String historyKind;
  final String noun;

  /// The restore option naming another place for it; null when there is
  /// no other place.
  final String? place;
  final TreeKind? tree;
}

/// Restores a deleted object; true when it was restored.
Future<bool> restoreObject(
  BuildContext context,
  RestoreKind kind,
  String id,
  String label,
) async {
  final client = context.read<Session>().client;
  Future<void> send(Json options) => switch (kind) {
    RestoreKind.item => client.restoreItem(id, options),
    RestoreKind.stock => client.restoreStock(id, options),
    RestoreKind.location => client.restoreLocation(id, options),
    RestoreKind.cls => client.restoreClass(id, options),
    RestoreKind.attribute => client.restoreAttribute(id, options),
  };
  try {
    try {
      await send(const {});
    } on ApiProblem catch (e) {
      if (!e.intoDeleted || kind.place == null || !context.mounted) rethrow;
      final options = await _askWhere(context, kind, e);
      if (options == null) return false;
      await send(options);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (context.mounted) showMessage(context, 'Restored $label.');
  return true;
}

/// Asks how to restore something that is in something deleted: with it, or
/// somewhere else. Null when cancelled.
Future<Json?> _askWhere(
  BuildContext context,
  RestoreKind kind,
  ApiProblem problem,
) async {
  final placeNoun = kind.tree == TreeKind.classes ? 'class' : 'location';
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Restore this ${kind.noun}'),
      content: Text(
        '${problem.detail}.\n\nRestore that $placeNoun too, or put the ${kind.noun} somewhere else?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'elsewhere'),
          child: const Text('Somewhere else…'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'parents'),
          child: Text('Restore the $placeNoun too'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'parents') return {'with_parents': true};
  final place = await pickNode(
    context,
    kind.tree!,
    title: 'Restore it in',
    forUse: kind == RestoreKind.item || kind == RestoreKind.stock,
    allowTopLevel: kind.place == 'parent',
  );
  if (place == null) return null;
  return {kind.place!: place == topLevel ? null : place};
}

/// The banner at the top of a deleted object's screen: when and by whom it
/// was deleted (from its history, which admins may read, and everyone for
/// items and stock rows), and Restore (when the role may delete it). A stock row a move merged into another can't be
/// restored; the banner leads to that row instead.
class DeletedBanner extends StatelessWidget {
  const DeletedBanner({
    super.key,
    required this.kind,
    required this.id,
    required this.label,
    required this.canRestore,
    required this.onRestored,
    this.mergedInto,
    this.onOpenMerged,
  });

  final RestoreKind kind;
  final String id;
  final String label;
  final bool canRestore;
  final VoidCallback onRestored;
  final String? mergedInto;
  final VoidCallback? onOpenMerged;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final scheme = Theme.of(context).colorScheme;
    final merged = mergedInto != null;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.delete_outline, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    merged
                        ? 'This ${kind.noun} was merged into $mergedInto by a move.'
                        : 'This ${kind.noun} is deleted.',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            if (session.isAdmin ||
                kind == RestoreKind.item ||
                kind == RestoreKind.stock)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 4),
                child: _DeletedWhen(kind: kind, id: id),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: merged
                  ? TextButton(
                      onPressed: onOpenMerged,
                      child: Text('Open $mergedInto'),
                    )
                  : canRestore
                  ? TextButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Restore'),
                      onPressed: () async {
                        if (await restoreObject(context, kind, id, label)) {
                          onRestored();
                        }
                      },
                    )
                  : const SizedBox(height: 8),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Deleted on 27 Oct 2026 at 14:05 by anna@example.com", from history.
class _DeletedWhen extends StatelessWidget {
  const _DeletedWhen({required this.kind, required this.id});

  final RestoreKind kind;
  final String id;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onErrorContainer,
      fontSize: 13,
    );
    return FutureBuilder<HistoryEntry?>(
      future: client
          .history(kind.historyKind, id, limit: 50)
          .then(
            (page) => page.rows
                .where((h) => h.rowId == id && h.marksDeleted)
                .firstOrNull,
          ),
      builder: (context, snapshot) {
        final h = snapshot.data;
        if (h == null) return const SizedBox.shrink();
        final when = h.happenedAt == null
            ? ''
            : ' on ${longDate(h.happenedAt!)}';
        final by = h.who == null ? '' : ' by ${h.who}';
        return Text('Deleted$when$by.', style: style);
      },
    );
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "27 Oct 2026 at 14:05".
String longDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year} at ${two(t.hour)}:${two(t.minute)}';
}

/// "14:05".
String clockTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

/// "Today", "Yesterday", or "Mon 26 Oct 2026".
String dayHeading(DateTime t, [DateTime? now]) {
  now ??= DateTime.now();
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]} ${t.year}';
}
