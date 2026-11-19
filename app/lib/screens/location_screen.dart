import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../camera.dart';
import '../api/input.dart';
import '../session.dart';
import '../widgets/files.dart';
import '../widgets/common.dart';
import 'node_delete.dart';

/// Stock rows shown on a location screen at most; more are counted.
const _stockShown = 1000;

class _LocationData {
  const _LocationData(this.location, this.tree, this.stock, this.more);

  final Location location;
  final Tree tree;
  final List<Stock> stock;

  /// Whether there are more stock rows than are shown.
  final bool more;
}

/// A location, like `wtf location get`: its path, what's inside it, the
/// stock at it and below it.
class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<_LocationData>(
      key: ValueKey(code),
      title: 'Location $code',
      // Also after a change by this session's camera: what is here changes
      // with its stock rows too.
      refreshOn: anyOf([
        client.treeChanges.where((k) => k == TreeKind.locations),
        client.remoteChanges,
      ]),
      load: () async {
        final target = await client.code(code);
        if (target is CodeGone) {
          throw const InputError(
            "This label's item, stock row or location has been deleted.",
          );
        }
        if (target is! CodeLocation) {
          throw InputError('There is no location with the code $code.');
        }
        final l = await client.location(target.location.id);
        final tree = await client.tree(TreeKind.locations);
        final page = await client.stockList(
          locationId: l.id,
          limit: _stockShown,
        );
        return _LocationData(l, tree, page.rows, page.more);
      },
      builder: (context, data, reload) {
        final l = data.location;
        final tree = data.tree;
        final node = tree[l.id];
        final here = data.stock.where((s) => s.location == l.id).toList();
        final below = data.stock.where((s) => s.location != l.id).toList();
        String relative(String id) {
          final p = tree.pathOf(id);
          final prefix = '${tree.pathOf(l.id)}/';
          return p.startsWith(prefix) ? p.substring(prefix.length) : p;
        }

        Future<void> open(String path) async {
          await context.push(path);
          reload();
        }

        // Admins set up locations, photos included; users put stock in
        // them.
        final write = session.isAdmin;

        return CameraSubject(
          path: '/locations/$code',
          target: CameraTarget(type: 'location', id: l.id, name: l.name),
          child: Scaffold(
            appBar: AppBar(
              title: Text(l.name),
              actions: [
                if (write)
                  PopupMenuButton<String>(
                    onSelected: (action) async {
                      switch (action) {
                        case 'photo':
                          if (await editPhoto(
                            context,
                            owner: '/locations/${l.id}',
                            hasPhoto: l.photo != null,
                            remove: () =>
                                client.patchLocation(l.id, {'photo': null}),
                          )) {
                            reload();
                          }
                        case 'edit':
                          if (await context.push('/locations/${l.code}/edit') ==
                              true) {
                            reload();
                          }
                        case 'add':
                          open('/locations/new?parent=${l.id}');
                        case 'delete':
                          if (await deleteNode(
                                context,
                                TreeKind.locations,
                                l.id,
                                l.pathText,
                              ) &&
                              context.mounted) {
                            leave(context, '/locations');
                          }
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'photo', child: Text('Photo…')),
                      PopupMenuItem(
                        value: 'add',
                        child: Text('Add a location inside'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Delete…')),
                    ],
                  ),
              ],
            ),
            floatingActionButton: session.canWriteItems && !l.container
                ? FloatingActionButton.extended(
                    onPressed: () => open('/stock/new?location=${l.id}'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add stock here'),
                  )
                : null,
            body: Readable(
              child: RefreshIndicator(
                onRefresh: reload,
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    WithPhoto(
                      photo: l.photo,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: PathLinks(
                            parts: [
                              for (final p in l.path)
                                (
                                  p.name,
                                  p.id == l.id || tree[p.id]?.code == null
                                      ? null
                                      : '/locations/${tree[p.id]!.code}',
                                ),
                            ],
                          ),
                        ),
                        Field('Code', l.code),
                        if (l.container)
                          const Field(
                            'Container',
                            'yes',
                            note: 'holds only other locations',
                          ),
                      ],
                    ),
                    SectionTitle(
                      'Inside',
                      trailing: write
                          ? TextButton.icon(
                              onPressed: () =>
                                  open('/locations/new?parent=${l.id}'),
                              icon: const Icon(Icons.add),
                              label: const Text('Add'),
                            )
                          : null,
                    ),
                    if (node == null || node.children.isEmpty)
                      const EmptyNote('No locations inside.'),
                    for (final c in node?.children ?? const <TreeNode>[])
                      ListTile(
                        dense: true,
                        leading: PhotoOrIcon(
                          c.photo,
                          icon: c.container
                              ? Icons.folder_outlined
                              : Icons.place_outlined,
                        ),
                        title: Text(c.container ? '${c.name}/' : c.name),
                        trailing: Text(c.code ?? ''),
                        onTap: () => open('/locations/${c.code}'),
                      ),
                    if (!l.container) ...[
                      const SectionTitle('Stock here'),
                      if (here.isEmpty) const EmptyNote('No stock here.'),
                      for (final s in here)
                        _StockRow(
                          stock: s,
                          place: null,
                          onTap: () => open('/stock/${s.code}'),
                        ),
                    ],
                    if (below.isNotEmpty) ...[
                      const SectionTitle('Stock further in'),
                      for (final s in below)
                        _StockRow(
                          stock: s,
                          place: relative(s.location),
                          onTap: () => open('/stock/${s.code}'),
                        ),
                    ],
                    if (data.more)
                      const EmptyNote(
                        '… and more stock rows than are shown here.',
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StockRow extends StatelessWidget {
  const _StockRow({
    required this.stock,
    required this.place,
    required this.onTap,
  });

  final Stock stock;
  final String? place;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      // The row's own photo, else its item's.
      leading: PhotoOrIcon(
        stock.photo ?? stock.item.photo,
        icon: Icons.inventory_2_outlined,
      ),
      title: Text(stock.item.name),
      subtitle: Text([stock.code, ?place].join('  ·  ')),
      trailing: Text(stock.amountText),
      onTap: onTap,
    );
  }
}
