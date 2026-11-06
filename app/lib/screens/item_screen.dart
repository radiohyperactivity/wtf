import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';

/// The values of an item or a stock row ([stock]), in its class's order;
/// those that follow the class's default are marked. Files are listed apart
/// ([fileTiles]).
List<Widget> valueFields(
  ClassDetail cls,
  Values values,
  Set<String> defaulted, {
  required bool stock,
}) => [
  for (final a in cls.scoped(stock: stock))
    if (!a.isFile && values[a.name] != null)
      Field(
        a.name,
        formatValue(a, values[a.name]),
        note: defaulted.contains(a.name) ? '(default)' : null,
        link: a.type == 'url',
      ),
];

/// The files of an item's or a stock row's attachment attributes, at
/// [owner]: those it has, and with [onChanged] the others too, to upload.
/// Removing one is a patch, which [patch] sends.
List<Widget> fileTiles(
  ClassDetail cls,
  String owner,
  Values values, {
  required bool stock,
  VoidCallback? onChanged,
  required Future<void> Function(Json changes) patch,
}) => [
  for (final a in cls.scoped(stock: stock))
    if (a.isFile && (values[a.name] != null || onChanged != null))
      FileValueTile(
        owner: owner,
        attribute: a,
        hash: values[a.name] as String?,
        onChanged: onChanged,
        remove: () => patch({
          'values': {a.name: null},
        }),
      ),
];

/// A stock row's reference and serial, when it has them: "ref PO-12 ·
/// serial 4711".
String stockMarks(Stock s) => [
  if (s.reference case final r?) 'ref $r',
  if (s.serial case final n?) 'serial $n',
].join(' · ');

/// An item, like `wtf item get`: class, values, files, stock rows with
/// their locations. The code may also be one of its stock rows' (as in the
/// CLI's references).
class ItemScreen extends StatelessWidget {
  const ItemScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<(ItemDetail, ClassDetail, Tree)>(
      key: ValueKey(code),
      title: 'Item $code',
      refreshOn: client.treeChanges,
      load: () async {
        final target = await client.code(code);
        final ItemDetail item = switch (target) {
          CodeItem(:final item) => item,
          CodeStock(:final stock) => await client.item(stock.item.id),
          CodeGone() => throw const InputError(
            "This label's item, stock row or location has been deleted.",
          ),
          _ => throw InputError('There is no item with the code $code.'),
        };
        return (
          item,
          await client.cls(item.cls.id),
          await client.tree(TreeKind.locations),
        );
      },
      builder: (context, data, reload) {
        final (item, cls, locations) = data;
        final owner = '/items/${item.id}';
        Future<void> open(String path) async {
          await context.push(path);
          reload();
        }

        final write = session.canWriteItems;

        Future<void> delete() async {
          final ok = await confirmDelete(
            context,
            item.name,
            note: item.stock.isEmpty ? null : 'It still has stock, which must be deleted or moved away first.',
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

        final files = fileTiles(
          cls,
          owner,
          item.values,
          stock: false,
          onChanged: write ? reload : null,
          patch: (changes) => client.patchItem(item.id, changes),
        );

        return Scaffold(
          appBar: AppBar(
            title: Text(item.name),
            actions: [
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
                  onSelected: (action) async {
                    switch (action) {
                      case 'photo':
                        if (await editPhoto(
                          context,
                          owner: owner,
                          hasPhoto: item.photo != null,
                          remove: () =>
                              client.patchItem(item.id, {'photo': null}),
                        )) {
                          reload();
                        }
                      case 'delete':
                        delete();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'photo', child: Text('Photo…')),
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
                  // The class's values are details like the code and class.
                  WithPhoto(
                    photo: item.photo,
                    children: [
                      const SizedBox(height: 8),
                      Field('Code', item.code),
                      Field(
                        'Class',
                        item.classPath,
                        // The class screens are for admins.
                        onTap: session.isAdmin
                            ? () => open('/classes/${item.cls.id}')
                            : null,
                      ),
                      Field('Counted in', item.unit ?? 'pieces'),
                      ...valueFields(
                        cls,
                        item.values,
                        item.defaulted,
                        stock: false,
                      ),
                    ],
                  ),
                  if (files.isNotEmpty) ...[
                    const SectionTitle('Files'),
                    ...files,
                  ],
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
                      leading: PhotoOrIcon(s.photo, icon: Icons.place_outlined),
                      title: Text(locations.pathOf(s.location)),
                      subtitle: Text(
                        [
                          s.code,
                          stockMarks(s),
                        ].where((t) => t.isNotEmpty).join('  ·  '),
                      ),
                      trailing: Text(
                        s.amountText,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      onTap: () => open('/stock/${s.code}'),
                    ),
                    if (valueFields(cls, s.values, s.defaulted, stock: true)
                        case final fields when fields.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 56),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: fields,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
