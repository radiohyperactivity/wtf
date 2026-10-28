import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/attachments.dart';
import '../widgets/common.dart';
import '../widgets/restore.dart';

/// The values of an item or a stock row; class defaults are marked.
List<Widget> valueFields(List<Value> values) => [
  for (final v in values)
    Field(
      v.attribute.name,
      v.text,
      note: v.isDefault ? '(default)' : null,
      link: v.attribute.datatype == 'url',
    ),
];

/// An item, like `wtf item get`: class, values, stock rows with their
/// locations, attachments. The code may also be one of its stock rows' (as in
/// the CLI's references).
class ItemScreen extends StatelessWidget {
  const ItemScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<(ItemDetail, Map<String, String>, Tree)>(
      key: ValueKey(code),
      title: 'Item $code',
      refreshOn: client.treeChanges,
      load: () async {
        final target = await client.code(code);
        final ItemDetail item = switch (target) {
          CodeItem(:final item) => item,
          CodeStock(:final stock) => await client.item(stock.item.id),
          _ => throw InputError('There is no item with the code $code.'),
        };
        return (
          item,
          await client.locationPaths(item.stock.map((s) => s.location)),
          // Cached already, for the paths.
          await client.tree(TreeKind.locations),
        );
      },
      builder: (context, data, reload) {
        final (item, paths, locations) = data;
        Future<void> open(String path) async {
          await context.push(path);
          reload();
        }

        // A deleted item can only be looked at, and restored.
        final write = session.canWriteData && !item.deleted;

        Future<void> delete() async {
          final ok = await confirm(
            context,
            title: 'Delete item ${item.name}?',
            message: item.stock.isEmpty ? null : 'It still has stock, which must be deleted or moved away first.',
          );
          if (!ok || !context.mounted) return;
          try {
            await client.deleteItem(item.id);
            if (context.mounted) {
              showMessage(context, 'Deleted ${item.name}.');
              leave(context, '/');
            }
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(item.name),
            actions: [
              if (session.canReadHistory)
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'History',
                  onPressed: () => context.push(
                    '/history/items/${item.id}?title=${Uri.encodeComponent(item.name)}',
                  ),
                ),
              if (write) ...[
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () async {
                    if (await context.push('/items/${item.code}/edit') ==
                        true) {
                      reload();
                    }
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'delete') delete();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete…')),
                  ],
                ),
              ],
            ],
          ),
          floatingActionButton: write
              ? FloatingActionButton.extended(
                  onPressed: () => open('/stock/new?item=${item.id}'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add stock'),
                )
              : null,
          body: Readable(
            child: RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  if (item.deleted)
                    DeletedBanner(
                      kind: RestoreKind.item,
                      id: item.id,
                      label: item.name,
                      canRestore: session.canWriteData,
                      onRestored: reload,
                    ),
                  // The class's values are details like the code and class.
                  WithPhoto(
                    photo: item.photo,
                    children: [
                      const SizedBox(height: 8),
                      Field('Code', item.code),
                      Field(
                        'Class',
                        item.cls.pathText,
                        onTap: () => open('/classes/${item.cls.id}'),
                      ),
                      Field(
                        'Stock in',
                        item.unit == null
                            ? 'pieces'
                            : unitLabel(item.unit!, lock: item.unitLock),
                      ),
                      ...valueFields(item.values),
                      MissingNote(item.missing.map((m) => m.name).toList()),
                    ],
                  ),
                  SectionTitle(
                    'Stock',
                    trailing: write
                        ? TextButton.icon(
                            onPressed: () => open('/stock/new?item=${item.id}'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add'),
                          )
                        : null,
                  ),
                  if (item.stock.isEmpty) const EmptyNote('No stock.'),
                  for (final s in item.stock) ...[
                    ListTile(
                      // The row's own photo, else its location's.
                      leading: PhotoOrIcon(
                        s.photo ?? locations[s.location]?.photo,
                        icon: Icons.place_outlined,
                      ),
                      title: Text(paths[s.location] ?? s.location),
                      subtitle: Text(s.code),
                      trailing: Text(
                        s.quantityText,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      onTap: () => open('/stock/${s.code}'),
                    ),
                    if (s.values.isNotEmpty || s.missing.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 56),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...valueFields(s.values),
                            MissingNote(s.missing.map((m) => m.name).toList()),
                          ],
                        ),
                      ),
                  ],
                  AttachmentList(
                    item.attachments,
                    ownerPath: '/items/${item.id}',
                    photo: item.photo,
                    onChanged: write ? reload : null,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
