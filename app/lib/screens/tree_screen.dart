import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';

/// Where a tree node's screen is: locations by label code, classes by id.
String nodePath(TreeKind kind, TreeNode n) =>
    kind == TreeKind.locations ? '/locations/${n.code}' : '/classes/${n.id}';

/// The location or class tree, like `wtf location tree`: expandable, with a
/// filter that shows the matching paths. Containers show as folders.
class TreeScreen extends StatefulWidget {
  const TreeScreen({super.key, required this.kind});

  final TreeKind kind;

  @override
  State<TreeScreen> createState() => _TreeScreenState();
}

class _TreeScreenState extends State<TreeScreen> {
  final _filter = TextEditingController();
  final Set<String> _open = {};

  bool get _locations => widget.kind == TreeKind.locations;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final title = _locations ? 'Locations' : 'Classes';
    return Loader<Tree>(
      key: ValueKey(widget.kind),
      title: title,
      load: () => session.client.tree(widget.kind),
      refreshOn: session.client.treeChanges.where((k) => k == widget.kind),
      builder: (context, tree, reload) {
        final filter = _filter.text.trim();
        final rows =
            <(TreeNode, bool)>[]; // node, and whether it shows its whole path
        if (filter.isNotEmpty) {
          for (final n in tree.all) {
            if (matchesWords('${n.path} ${n.code ?? ''}', filter)) {
              rows.add((n, true));
            }
          }
        } else {
          void walk(List<TreeNode> nodes) {
            for (final n in nodes) {
              rows.add((n, false));
              if (_open.contains(n.id)) walk(n.children);
            }
          }

          walk(tree.roots);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                icon: const Icon(Icons.unfold_more),
                tooltip: 'Expand all',
                onPressed: () => setState(
                  () => _open.addAll(
                    tree.all
                        .where((n) => n.children.isNotEmpty)
                        .map((n) => n.id),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.unfold_less),
                tooltip: 'Collapse all',
                onPressed: () => setState(_open.clear),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload',
                onPressed: reload,
              ),
            ],
          ),
          floatingActionButton: session.canWriteModel
              ? FloatingActionButton.extended(
                  onPressed: () async {
                    await context.push(
                      _locations ? '/locations/new' : '/classes/new',
                    );
                    reload();
                  },
                  icon: const Icon(Icons.add),
                  label: Text(_locations ? 'New location' : 'New class'),
                )
              : null,
          body: Readable(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _filter,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.filter_list),
                      hintText: _locations
                          ? 'Filter by path or code'
                          : 'Filter by path',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? EmptyNote(
                          filter.isNotEmpty
                              ? 'Nothing matches.'
                              : _locations
                              ? 'No locations yet.'
                              : 'No classes yet.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final (n, whole) = rows[i];
                            return _NodeRow(
                              node: n,
                              whole: whole,
                              open: _open.contains(n.id),
                              onToggle: () => setState(
                                () => _open.contains(n.id)
                                    ? _open.remove(n.id)
                                    : _open.add(n.id),
                              ),
                              onTap: () async {
                                await context.push(nodePath(widget.kind, n));
                                reload();
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.whole,
    required this.open,
    required this.onToggle,
    required this.onTap,
  });

  final TreeNode node;
  final bool whole;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = node.children.isNotEmpty;
    final name = whole ? node.path : node.name;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: whole ? 8 : 8.0 + 20 * node.depth,
          right: 16,
        ),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: hasChildren && !whole
                    ? IconButton(
                        icon: Icon(
                          open ? Icons.expand_more : Icons.chevron_right,
                        ),
                        tooltip: open ? 'Collapse' : 'Expand',
                        onPressed: onToggle,
                      )
                    : null,
              ),
              Icon(
                node.container
                    ? Icons.folder_outlined
                    : (node.code == null
                          ? Icons.category_outlined
                          : Icons.place_outlined),
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.container ? '$name/' : name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (node.code != null)
                Text(
                  node.code!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
