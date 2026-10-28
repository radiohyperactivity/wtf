import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/attachments.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/restore.dart';
import '../widgets/value_fields.dart';
import 'node_delete.dart';
import 'model_import.dart';

const _itemsShown = 100;

class _ClassData {
  const _ClassData(this.cls, this.tree, this.items);

  final ClassDetail cls;
  final Tree tree;
  final ResultPage<ItemListed> items;
}

/// A class, like `wtf class get`: its path, its attributes (own and
/// inherited), the classes below it and its items.
class ClassScreen extends StatelessWidget {
  const ClassScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<_ClassData>(
      key: ValueKey(id),
      title: 'Class',
      refreshOn: client.treeChanges.where((k) => k == TreeKind.classes),
      load: () async {
        final results = await Future.wait([
          client.cls(id),
          client.tree(TreeKind.classes),
          client.items(classId: id, limit: _itemsShown),
        ]);
        return _ClassData(
          results[0] as ClassDetail,
          results[1] as Tree,
          results[2] as ResultPage<ItemListed>,
        );
      },
      builder: (context, data, reload) {
        final c = data.cls;
        final node = data.tree[c.id];
        // A deleted class can only be looked at, and restored.
        final write = session.canWriteModel && !c.deleted;

        Future<void> open(String path) async {
          await context.push(path);
          reload();
        }

        Future<void> assign([ClassAttribute? current]) async {
          final attribute =
              current?.attribute ??
              await pickAttribute(
                context,
                exclude: {for (final a in c.attributes) a.attribute.id},
              );
          if (attribute == null || !context.mounted) return;
          if (await showAssignDialog(context, c, attribute, current) &&
              context.mounted) {
            reload();
          }
        }

        Future<void> unassign(ClassAttribute a) async {
          final ok = await confirm(
            context,
            title: 'Remove ${a.attribute.name} from ${c.name}?',
            action: 'Remove',
          );
          if (!ok || !context.mounted) return;
          try {
            await client.unassignAttribute(c.id, a.attribute.id);
            reload();
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }

        Widget attributeTile(ClassAttribute a) => ListTile(
          dense: true,
          title: Text(a.required ? '${a.attribute.name} *' : a.attribute.name),
          subtitle: Text(
            [
              a.attribute.datatype,
              if (a.attribute.unit case final u?)
                unitLabel(u, lock: a.attribute.unitLock),
              if (a.required) 'required',
              if (a.defaultText.isNotEmpty) 'default ${a.defaultText}',
              if (a.inherited) 'from ${data.tree.pathOf(a.definedOnClass)}',
            ].join(' · '),
          ),
          onTap: write && !a.inherited ? () => assign(a) : null,
          trailing: write && !a.inherited
              ? IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  tooltip: 'Remove from this class',
                  onPressed: () => unassign(a),
                )
              : null,
        );

        // The item's attributes and the stock rows' (per unit), each under
        // its own heading when it has any. Assign sits on the first heading,
        // or on a bare "Attributes" when there are none.
        List<Widget> attributeSections() {
          final assignButton = write
              ? TextButton.icon(
                  onPressed: assign,
                  icon: const Icon(Icons.add),
                  label: const Text('Assign'),
                )
              : null;
          final sections = [
            ('Item attributes', c.attributes.where((a) => !a.perUnit)),
            ('Stock attributes', c.attributes.where((a) => a.perUnit)),
          ].where((s) => s.$2.isNotEmpty).toList();
          if (sections.isEmpty) {
            return [
              if (assignButton != null)
                SectionTitle('Attributes', trailing: assignButton),
            ];
          }
          return [
            for (final (i, (title, attributes)) in sections.indexed) ...[
              SectionTitle(title, trailing: i == 0 ? assignButton : null),
              for (final a in attributes) attributeTile(a),
            ],
          ];
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(c.name),
            actions: [
              if (session.canReadHistory)
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'History',
                  onPressed: () => context.push(
                    '/history/classes/${c.id}?title=${Uri.encodeComponent(c.pathText)}',
                  ),
                ),
              if (write)
                PopupMenuButton<String>(
                  onSelected: (action) async {
                    switch (action) {
                      case 'edit':
                        if (await context.push('/classes/${c.id}/edit') ==
                            true) {
                          reload();
                        }
                      case 'add':
                        open('/classes/new?parent=${c.id}');
                      case 'assign':
                        assign();
                      case 'import':
                        await importModelFile(
                          context,
                          parentId: c.id,
                          parentPath: c.pathText,
                        );
                        reload();
                      case 'delete':
                        if (await deleteNode(
                              context,
                              TreeKind.classes,
                              c.id,
                              c.pathText,
                            ) &&
                            context.mounted) {
                          leave(context, '/classes');
                        }
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'add',
                      child: Text('Add a class below'),
                    ),
                    PopupMenuItem(
                      value: 'assign',
                      child: Text('Assign an attribute'),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      child: Text('Import a model here…'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete…')),
                  ],
                ),
            ],
          ),
          floatingActionButton:
              session.canWriteData && !c.container && !c.deleted
              ? FloatingActionButton.extended(
                  onPressed: () => open('/items/new?class=${c.id}'),
                  icon: const Icon(Icons.add),
                  label: const Text('New item'),
                )
              : null,
          body: Readable(
            child: RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  if (c.deleted)
                    DeletedBanner(
                      kind: RestoreKind.cls,
                      id: c.id,
                      label: c.name,
                      canRestore: session.canWriteModel,
                      onRestored: reload,
                    ),
                  WithPhoto(
                    photo: c.photo,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: PathLinks(
                          parts: [
                            for (final p in c.path)
                              (
                                p.name,
                                p.id == c.id ? null : '/classes/${p.id}',
                              ),
                          ],
                        ),
                      ),
                      if (c.container)
                        const Field(
                          'Container',
                          'yes',
                          note: 'holds only other classes',
                        ),
                    ],
                  ),
                  ...attributeSections(),
                  SectionTitle(
                    'Classes below',
                    trailing: write
                        ? TextButton.icon(
                            onPressed: () =>
                                open('/classes/new?parent=${c.id}'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add'),
                          )
                        : null,
                  ),
                  if (node == null || node.children.isEmpty)
                    const EmptyNote('None.'),
                  for (final child in node?.children ?? const <TreeNode>[])
                    ListTile(
                      dense: true,
                      leading: PhotoOrIcon(
                        child.photo,
                        icon: child.container
                            ? Icons.folder_outlined
                            : Icons.category_outlined,
                      ),
                      title: Text(
                        child.container ? '${child.name}/' : child.name,
                      ),
                      onTap: () => open('/classes/${child.id}'),
                    ),
                  SectionTitle(
                    'Items (${data.items.total}, with the classes below)',
                  ),
                  if (data.items.rows.isEmpty) const EmptyNote('No items.'),
                  for (final i in data.items.rows)
                    ListTile(
                      dense: true,
                      leading: PhotoOrIcon(
                        i.photo,
                        icon: Icons.inventory_2_outlined,
                      ),
                      title: Text(i.name),
                      subtitle: Text(
                        '${i.code}  ·  ${data.tree.pathOf(i.classId)}',
                      ),
                      trailing: Text(i.stockText),
                      onTap: () => open('/items/${i.code}'),
                    ),
                  if (data.items.total > data.items.rows.length)
                    EmptyNote(
                      '… and ${data.items.total - data.items.rows.length} more; search with this class to see them.',
                    ),
                  AttachmentList(
                    c.attachments,
                    ownerPath: '/classes/${c.id}',
                    photo: c.photo,
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

/// Assigns [attribute] to a class, or changes its assignment, like
/// `wtf class assign`: default, per unit, required. It replaces the whole
/// assignment, so the dialog starts from the current one. True when saved.
Future<bool> showAssignDialog(
  BuildContext context,
  ClassDetail cls,
  Attribute attribute,
  ClassAttribute? current,
) async {
  final client = context.read<Session>().client;
  final ValueInput input;
  try {
    final full = attribute.datatype == 'choice'
        ? await client.attribute(attribute.id)
        : attribute;
    final unit = full.unit;
    input = ValueInput(
      attribute: full,
      initial: current?.defaultText ?? '',
      units: unit == null ? null : await client.unitChoice(unit),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  var perUnit = current?.perUnit ?? false;
  var required = current?.required ?? false;
  final form = GlobalKey<FormState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: input.dispose,
      child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('${attribute.name} in ${cls.name}'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The attribute is in the title; this is its default.
                  ValueField(
                    input,
                    label: 'Default value',
                    helper:
                        'For items (or stock rows) without a value of '
                        'their own. Empty: no default',
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Per unit'),
                    subtitle: const Text(
                      'Values live on stock rows (each physical thing or batch) instead of on the item.',
                    ),
                    value: perUnit,
                    onChanged: (v) => setState(() => perUnit = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Required'),
                    subtitle: const Text(
                      'New items (or stock rows) need a value unless there is a default.',
                    ),
                    value: required,
                    onChanged: (v) => setState(() => required = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!form.currentState!.validate()) return;
                try {
                  await client.assignAttribute(
                    cls.id,
                    attribute.id,
                    defaultValue: input.parse(),
                    perUnit: perUnit,
                    required: required,
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: Text(current == null ? 'Assign' : 'Save'),
            ),
          ],
        ),
      ),
    ),
  );
  return saved ?? false;
}
