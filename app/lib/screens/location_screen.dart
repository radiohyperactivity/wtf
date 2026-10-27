import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/attachments.dart';
import '../widgets/common.dart';
import 'node_delete.dart';

/// Stock rows shown on a location screen at most; more are counted.
const _stockShown = 1000;

class _LocationData {
  const _LocationData(this.location, this.tree, this.stock, this.stockTotal);

  final Location location;
  final Tree tree;
  final List<Stock> stock;
  final int stockTotal;
}

/// A location, like `wtf location get`: its path, what's inside it, the
/// stock at it and below it, and its photos.
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
      refreshOn: client.treeChanges.where((k) => k == TreeKind.locations),
      load: () async {
        final target = await client.code(code);
        if (target is! CodeLocation) {
          throw InputError('There is no location with the code $code.');
        }
        final l = await client.location(target.location.id);
        final tree = await client.tree(TreeKind.locations);
        final page = await client.stockList(
          locationId: l.id,
          limit: _stockShown,
        );
        return _LocationData(l, tree, page.rows, page.total);
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

        return Scaffold(
          appBar: AppBar(
            title: Text(l.name),
            actions: [
              if (session.canReadHistory)
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'History',
                  onPressed: () => context.push(
                    '/history/locations/${l.id}?title=${Uri.encodeComponent(l.pathText)}',
                  ),
                ),
              if (session.canWriteModel)
                PopupMenuButton<String>(
                  onSelected: (action) async {
                    switch (action) {
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
                    PopupMenuItem(
                      value: 'add',
                      child: Text('Add a location inside'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete…')),
                  ],
                ),
            ],
          ),
          floatingActionButton: session.canWriteData && !l.container
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: PathLinks(
                      parts: [
                        for (final p in l.path)
                          (
                            p.name,
                            p.id == l.id
                                ? null
                                : '/locations/${tree[p.id]?.code ?? ''}',
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
                  SectionTitle(
                    'Inside',
                    trailing: session.canWriteModel
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
                      leading: Icon(
                        c.container
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
                  if (data.stockTotal > data.stock.length)
                    EmptyNote(
                      '… and ${data.stockTotal - data.stock.length} more stock rows.',
                    ),
                  AttachmentList(
                    l.attachments,
                    onChanged: session.canWriteModel ? reload : null,
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
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(stock.item.name),
      subtitle: Text([stock.code, ?place].join('  ·  ')),
      trailing: Text(stock.quantityText),
      onTap: onTap,
    );
  }
}
