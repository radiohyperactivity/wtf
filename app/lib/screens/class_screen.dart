import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart' show inputText;
import 'model_import.dart';
import 'node_delete.dart';

const _itemsShown = 100;

class _ClassData {
  const _ClassData(this.cls, this.tree, this.items);

  final ClassDetail cls;
  final Tree tree;
  final ResultPage<ItemListed> items;
}

/// A class, like `wtf class get`: its path, its attributes (own and
/// inherited), the classes below it and its items. Admins change its
/// attributes here; every change says first what it would rewrite.
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
        final write = session.isAdmin;

        Future<void> open(String path) async {
          await context.push(path);
          reload();
        }

        Future<void> add() async {
          if (await showAttributeDialog(context, c) && context.mounted) {
            reload();
          }
        }

        Widget attributeTile(Attribute a) => ListTile(
          dense: true,
          leading: a.isFile ? Icon(attributeIcon(a)) : null,
          title: Text(a.required ? '${a.name} *' : a.name),
          subtitle: Text(
            [
              typeLabel(a.type),
              ?a.unit,
              if (a.type == 'choice') a.choices.join(', '),
              if (a.media.isNotEmpty) a.media.join(', '),
              if (a.required) 'required',
              if (a.defaultText.isNotEmpty) 'default ${a.defaultText}',
              if (a.inherited) 'from ${data.tree.pathOf(a.classId)}',
            ].join(' · '),
          ),
          // An inherited one is changed where it is defined.
          onTap: !write
              ? null
              : a.inherited
              ? () => open('/classes/${a.classId}')
              : () async {
                  if (await showAttributeDialog(context, c, current: a) &&
                      context.mounted) {
                    reload();
                  }
                },
          trailing: write && !a.inherited
              ? _AttributeMenu(cls: c, attribute: a, onChanged: reload)
              : null,
        );

        // The item's attributes and the stock rows', each under its own
        // heading when it has any. Add sits on the first heading, or on a
        // bare "Attributes" when there are none.
        List<Widget> attributeSections() {
          final addButton = write
              ? TextButton.icon(
                  onPressed: add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                )
              : null;
          final sections = [
            ('Item attributes', c.scoped(stock: false)),
            ('Stock attributes', c.scoped(stock: true)),
          ].where((s) => s.$2.isNotEmpty).toList();
          if (sections.isEmpty) {
            return [
              SectionTitle('Attributes', trailing: addButton),
              const EmptyNote('None.'),
            ];
          }
          return [
            for (final (i, (title, attributes)) in sections.indexed) ...[
              SectionTitle(title, trailing: i == 0 ? addButton : null),
              for (final a in attributes) attributeTile(a),
            ],
          ];
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(c.name),
            actions: [
              // For admins, as are the class screens: changing the class,
              // and exporting it.
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
                      case 'attribute':
                        add();
                      case 'export':
                        await exportModelFile(context, c.id, c.name);
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
                      value: 'attribute',
                      child: Text('Add an attribute'),
                    ),
                    PopupMenuItem(
                      value: 'export',
                      child: Text('Export as a model file…'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete…')),
                  ],
                ),
            ],
          ),
          floatingActionButton: session.canWriteItems && !c.container
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: PathLinks(
                      parts: [
                        for (final p in c.path)
                          (p.name, p.id == c.id ? null : '/classes/${p.id}'),
                      ],
                    ),
                  ),
                  if (c.container)
                    const Field(
                      'Container',
                      'yes',
                      note: 'holds only other classes',
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
                      leading: Icon(
                        child.container
                            ? Icons.folder_outlined
                            : Icons.category_outlined,
                      ),
                      title: Text(
                        child.container ? '${child.name}/' : child.name,
                      ),
                      onTap: () => open('/classes/${child.id}'),
                    ),
                  const SectionTitle('Items, with the classes below'),
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
                  if (data.items.more)
                    ListTile(
                      dense: true,
                      title: const Text('More…'),
                      subtitle: const Text('Search with this class'),
                      onTap: () => context.push('/found?class=${c.id}'),
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

/// Runs a change of a class's attributes: first as a dry run, which says
/// what it would rewrite (or is refused as the change would be), then, when
/// the user agrees, for real. True when it was done.
Future<bool> runChange(
  BuildContext context, {
  required String title,
  required Future<ClassChange> Function(bool dryRun) change,
  String action = 'Save',
  bool destructive = false,
}) async {
  final ClassChange preview;
  try {
    preview = await change(true);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final ok = await confirm(
    context,
    title: title,
    message: preview.rewrites,
    action: action,
    destructive: destructive,
  );
  if (!ok || !context.mounted) return false;
  try {
    await change(false);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// The menu of an attribute the class defines: rename, its choices, remove.
class _AttributeMenu extends StatelessWidget {
  const _AttributeMenu({
    required this.cls,
    required this.attribute,
    required this.onChanged,
  });

  final ClassDetail cls;
  final Attribute attribute;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final a = attribute;
    return PopupMenuButton<String>(
      tooltip: a.name,
      onSelected: (action) async {
        final bool done;
        switch (action) {
          case 'edit':
            done = await showAttributeDialog(context, cls, current: a);
          case 'rename':
            final name = await askText(
              context,
              title: 'Rename ${a.name}',
              label: 'Name',
              initial: a.name,
              validate: attributeNameProblem,
            );
            if (name == null || name == a.name || !context.mounted) return;
            done = await runChange(
              context,
              title: 'Rename ${a.name} to $name?',
              action: 'Rename',
              change: (dryRun) =>
                  client.renameAttribute(cls.id, a.name, name, dryRun: dryRun),
            );
          case 'choices':
            done = await showChoicesDialog(context, cls, a);
          default:
            done = await runChange(
              context,
              title: 'Remove ${a.name} from ${cls.name}?',
              action: 'Remove',
              destructive: true,
              change: (dryRun) =>
                  client.removeAttribute(cls.id, a.name, dryRun: dryRun),
            );
        }
        if (done) onChanged();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'edit', child: Text('Edit…')),
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        if (a.type == 'choice')
          const PopupMenuItem(value: 'choices', child: Text('Choices…')),
        const PopupMenuItem(value: 'remove', child: Text('Remove…')),
      ],
    );
  }
}

/// Why [name] can't be an attribute's name, or null when it can.
String? attributeNameProblem(String name) {
  name = name.trim();
  if (name.isEmpty) return 'Enter a name';
  if (fixedFields.contains(name.toLowerCase())) {
    return '"$name" is a field of every item or stock row';
  }
  return null;
}

/// Asks for one line of text; null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? Function(String text)? validate,
  String action = 'Save',
}) {
  final text = TextEditingController(text: initial);
  final form = GlobalKey<FormState>();
  void done(BuildContext context) {
    if (form.currentState!.validate()) Navigator.pop(context, text.text.trim());
  }

  return showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: text.dispose,
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: TextFormField(
              controller: text,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
              validator: (v) =>
                  validate?.call(v ?? '') ??
                  ((v ?? '').trim().isEmpty ? 'Enter some text' : null),
              onFieldSubmitted: (_) => done(context),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: () => done(context), child: Text(action)),
        ],
      ),
    ),
  );
}

/// Splits a list typed in a field: one per line, or separated by commas.
List<String> _splitList(String text) => [
  for (final s in text.split(RegExp(r'[,\n]')))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Adds an attribute to [cls], or changes [current], one it defines, like
/// `wtf class attribute add` and `… set`: its name, where its values live
/// (on the item or on each stock row) and its type when adding, which never
/// change; then required, unit, default, choices (when adding; afterwards
/// they have a dialog of their own), media types and order. A dry run says
/// what the change would rewrite first. True when saved.
Future<bool> showAttributeDialog(
  BuildContext context,
  ClassDetail cls, {
  Attribute? current,
}) async {
  final client = context.read<Session>().client;
  final name = TextEditingController(text: current?.name ?? '');
  final unit = TextEditingController(text: current?.unit ?? '');
  // A number without its unit, which is a label of its own.
  final initialDefault = inputText(current?.defaultValue);
  final defaultValue = TextEditingController(text: initialDefault);
  final choices = TextEditingController(
    text: current?.choices.join('\n') ?? '',
  );
  final media = TextEditingController(text: current?.media.join(', ') ?? '');
  final order = TextEditingController(
    text: current == null ? '' : '${current.order}',
  );
  var scope = current?.scope ?? 'item';
  var type = current?.type ?? 'text';
  var required = current?.required ?? false;
  final form = GlobalKey<FormState>();

  // The attribute as the form has it, to check the default against.
  Attribute typed() => Attribute(
    name: name.text.trim(),
    scope: scope,
    type: type,
    required: required,
    unit: (type == 'integer' || type == 'decimal') && unit.text.trim() != ''
        ? unit.text.trim()
        : null,
    choices: type == 'choice'
        ? (current?.choices ?? _splitList(choices.text))
        : const [],
    media: type == 'attachment' ? _splitList(media.text) : const [],
    order: int.tryParse(order.text.trim()) ?? 0,
  );

  Object? parsedDefault() {
    final text = defaultValue.text.trim();
    return text.isEmpty || type == 'attachment'
        ? null
        : parseValue(typed(), text);
  }

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: () {
        name.dispose();
        unit.dispose();
        defaultValue.dispose();
        choices.dispose();
        media.dispose();
        order.dispose();
      },
      child: StatefulBuilder(
        builder: (context, setState) {
          final number = type == 'integer' || type == 'decimal';
          Future<void> save() async {
            if (!form.currentState!.validate()) return;
            final a = typed();
            final def = parsedDefault();
            final bool done;
            if (current == null) {
              final added = Attribute(
                name: a.name,
                scope: a.scope,
                type: a.type,
                required: a.required,
                unit: a.unit,
                defaultValue: def,
                choices: a.choices,
                media: a.media,
                order: a.order,
              );
              done = await runChange(
                context,
                title: 'Add ${a.name} to ${cls.name}?',
                action: 'Add',
                change: (dryRun) =>
                    client.addAttribute(cls.id, added, dryRun: dryRun),
              );
            } else {
              final changes = <String, Object?>{
                if (a.required != current.required) 'required': a.required,
                if (a.unit != current.unit) 'unit': a.unit,
                if (defaultValue.text.trim() != initialDefault) 'default': def,
                if (type == 'attachment' &&
                    a.media.join(',') != current.media.join(','))
                  'media': a.media.isEmpty ? null : a.media,
                if (a.order != current.order && a.order > 0) 'order': a.order,
              };
              if (changes.isEmpty) {
                if (context.mounted) Navigator.pop(context, false);
                return;
              }
              done = await runChange(
                context,
                title: 'Change ${current.name}?',
                change: (dryRun) => client.changeAttribute(
                  cls.id,
                  current.name,
                  changes,
                  dryRun: dryRun,
                ),
              );
            }
            if (done && context.mounted) Navigator.pop(context, true);
          }

          return AlertDialog(
            title: Text(
              current == null
                  ? 'New attribute of ${cls.name}'
                  : '${current.name} in ${cls.name}',
            ),
            content: SizedBox(
              width: 440,
              child: Form(
                key: form,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (current == null) ...[
                        TextFormField(
                          controller: name,
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'Name'),
                          validator: (v) => attributeNameProblem(v ?? ''),
                        ),
                        const SizedBox(height: 12),
                        SelectKeys<String>(
                          options: [
                            for (final t in attributeTypes) (t, typeLabel(t)),
                          ],
                          value: type,
                          onChanged: (t) => setState(() => type = t),
                          child: DropdownButtonFormField<String>(
                            initialValue: type,
                            decoration: const InputDecoration(
                              labelText: 'Type',
                              helperText: "It can't be changed afterwards.",
                            ),
                            items: [
                              for (final t in attributeTypes)
                                DropdownMenuItem(
                                  value: t,
                                  child: Text(typeLabel(t)),
                                ),
                            ],
                            onChanged: (t) => setState(() => type = t!),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('Values on'),
                        const SizedBox(height: 4),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'item', label: Text('Item')),
                            ButtonSegment(
                              value: 'stock',
                              label: Text('Stock row'),
                            ),
                          ],
                          selected: {scope},
                          onSelectionChanged: (s) =>
                              setState(() => scope = s.single),
                        ),
                      ] else
                        Text(
                          '${typeLabel(type)}, on ${scope == 'stock' ? 'each stock row' : 'the item'}.',
                        ),
                      if (type == 'choice' && current == null)
                        TextFormField(
                          controller: choices,
                          minLines: 2,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: 'Choices',
                            helperText: 'One per line, or separated by commas',
                          ),
                          validator: (v) => _splitList(v ?? '').isEmpty
                              ? 'At least one choice'
                              : null,
                          onChanged: (_) => setState(() {}),
                        ),
                      if (number)
                        TextFormField(
                          controller: unit,
                          decoration: const InputDecoration(
                            labelText: 'Unit',
                            hintText: 'mm, kg, MHz …',
                            helperText:
                                'A label after the numbers; nothing converts',
                          ),
                        ),
                      if (type == 'attachment')
                        TextFormField(
                          controller: media,
                          decoration: const InputDecoration(
                            labelText: 'File types',
                            hintText: 'application/pdf, image/*',
                            helperText: 'Empty: any',
                          ),
                        )
                      else
                        TextFormField(
                          controller: defaultValue,
                          decoration: InputDecoration(
                            labelText: 'Default',
                            suffixText: number ? unit.text.trim() : null,
                            helperText:
                                'For items (or stock rows) without a value of '
                                'their own. Empty: none',
                            helperMaxLines: 2,
                          ),
                          validator: (_) {
                            try {
                              parsedDefault();
                              return null;
                            } on InputError catch (e) {
                              return e.message;
                            }
                          },
                        ),
                      if (current != null)
                        TextFormField(
                          controller: order,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Order',
                            helperText: 'Its place among the attributes, smallest first',
                          ),
                          validator: (v) =>
                              int.tryParse((v ?? '').trim()) == null
                              ? 'An integer'
                              : null,
                        ),
                      SwitchTile(
                        title: const Text('Required'),
                        subtitle: const Text(
                          'Every item (or stock row) has a value; without a '
                          'default, those that lack one stop it.',
                        ),
                        value: required,
                        onChanged: (v) => setState(() => required = v),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: save,
                child: Text(current == null ? 'Add' : 'Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
  return saved ?? false;
}

/// A choice attribute's choices: add, rename and remove them, each a change
/// of the class that a dry run says the cost of first. True when something
/// changed.
Future<bool> showChoicesDialog(
  BuildContext context,
  ClassDetail cls,
  Attribute attribute,
) async {
  final client = context.read<Session>().client;
  var choices = attribute.choices;
  var changed = false;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> run(
          String title,
          String action,
          Future<ClassChange> Function(bool dryRun) change, {
          bool destructive = false,
        }) async {
          ClassChange? last;
          final done = await runChange(
            context,
            title: title,
            action: action,
            destructive: destructive,
            change: (dryRun) async => last = await change(dryRun),
          );
          if (!done) return;
          changed = true;
          setState(() {
            choices = last!.cls.attribute(attribute.name)?.choices ?? choices;
          });
        }

        return AlertDialog(
          title: Text('Choices of ${attribute.name}'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in choices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Rename',
                          onPressed: () async {
                            final text = await askText(
                              context,
                              title: 'Rename $c',
                              label: 'Choice',
                              initial: c,
                            );
                            if (text == null || text == c || !context.mounted) {
                              return;
                            }
                            await run(
                              'Rename $c to $text?',
                              'Rename',
                              (dryRun) => client.renameChoice(
                                cls.id,
                                attribute.name,
                                c,
                                text,
                                dryRun: dryRun,
                              ),
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Remove',
                          onPressed: () => run(
                            'Remove $c?',
                            'Remove',
                            (dryRun) => client.removeChoice(
                              cls.id,
                              attribute.name,
                              c,
                              dryRun: dryRun,
                            ),
                            destructive: true,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                final text = await askText(
                  context,
                  title: 'New choice of ${attribute.name}',
                  label: 'Choice',
                  action: 'Next',
                );
                if (text == null || !context.mounted) return;
                await run(
                  'Add $text?',
                  'Add',
                  (dryRun) => client.addChoice(
                    cls.id,
                    attribute.name,
                    text,
                    dryRun: dryRun,
                  ),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
  return changed;
}
