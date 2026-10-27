import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/restore.dart';

String _describe(Attribute a) => [a.datatype, ?a.unitGroup?.name].join(' · ');

/// All attributes, like `wtf attribute list`.
class AttributesScreen extends StatefulWidget {
  const AttributesScreen({super.key});

  @override
  State<AttributesScreen> createState() => _AttributesScreenState();
}

class _AttributesScreenState extends State<AttributesScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Loader<List<Attribute>>(
      title: 'Attributes',
      load: session.client.attributes,
      builder: (context, attributes, reload) {
        final shown = attributes
            .where(
              (a) => matchesWords('${a.name} ${_describe(a)}', _filter.text),
            )
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Attributes'),
            actions: [
              // Attributes added, deleted or restored: how a deleted one is
              // found.
              if (session.canReadHistory)
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'History',
                  onPressed: () => context.push(
                    '/history/attributes?title=${Uri.encodeComponent('the attributes')}',
                  ),
                ),
            ],
          ),
          floatingActionButton: session.canWriteModel
              ? FloatingActionButton.extended(
                  onPressed: () async {
                    final created = await showAttributeDialog(context);
                    if (created != null && context.mounted) {
                      await context.push('/attributes/${created.id}');
                    }
                    reload();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New attribute'),
                )
              : null,
          body: Readable(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _filter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.filter_list),
                      hintText: 'Filter',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: shown.isEmpty
                      ? const EmptyNote('No attributes.')
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 88),
                          children: [
                            for (final a in shown)
                              ListTile(
                                title: Text(a.name),
                                subtitle: Text(_describe(a)),
                                onTap: () async {
                                  await context.push('/attributes/${a.id}');
                                  reload();
                                },
                              ),
                          ],
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

/// One attribute, like `wtf attribute get`, with the options of a choice
/// attribute (`wtf option add|set|delete`).
class AttributeScreen extends StatelessWidget {
  const AttributeScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<Attribute>(
      key: ValueKey(id),
      title: 'Attribute',
      load: () => client.attribute(id),
      builder: (context, a, reload) {
        // A deleted attribute can only be looked at, and restored.
        final write = session.canWriteModel && !a.deleted;

        Future<void> run(Future<void> Function() change) async {
          try {
            await change();
            reload();
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(a.name),
            actions: [
              if (session.canReadHistory)
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: 'History',
                  onPressed: () => context.push(
                    '/history/attributes/${a.id}?title=${Uri.encodeComponent(a.name)}',
                  ),
                ),
              if (write) ...[
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () async {
                    if (await showAttributeDialog(context, current: a) !=
                        null) {
                      reload();
                    }
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (_) async {
                    if (!await confirm(
                      context,
                      title: 'Delete attribute ${a.name}?',
                    )) {
                      return;
                    }
                    try {
                      await client.deleteAttribute(a.id);
                      if (context.mounted) leave(context, '/attributes');
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete…')),
                  ],
                ),
              ],
            ],
          ),
          body: Readable(
            child: ListView(
              children: [
                if (a.deleted)
                  DeletedBanner(
                    kind: RestoreKind.attribute,
                    id: a.id,
                    label: a.name,
                    canRestore: session.canWriteModel,
                    onRestored: reload,
                  ),
                const SizedBox(height: 8),
                Field('Type', a.datatype),
                if (a.unitGroup != null)
                  Field(
                    'Unit group',
                    a.unitGroup!.name,
                    note: a.unitGroup!.quantity.name,
                  ),
                if (a.datatype == 'choice') ...[
                  SectionTitle(
                    'Options',
                    trailing: write
                        ? TextButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Add'),
                            onPressed: () async {
                              final name = await askText(
                                context,
                                title: 'New option of ${a.name}',
                                label: 'Name',
                              );
                              if (name != null) {
                                run(() => client.addOption(a.id, name));
                              }
                            },
                          )
                        : null,
                  ),
                  if (a.options.isEmpty) const EmptyNote('No options yet.'),
                  for (final o in a.options)
                    ListTile(
                      dense: true,
                      title: Text(o.name),
                      onTap: write
                          ? () async {
                              final name = await askText(
                                context,
                                title: 'Rename option',
                                label: 'Name',
                                initial: o.name,
                              );
                              if (name != null && name != o.name) {
                                run(() => client.renameOption(o.id, name));
                              }
                            }
                          : null,
                      trailing: write
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Delete option',
                              onPressed: () async {
                                if (await confirm(
                                  context,
                                  title: 'Delete option ${o.name}?',
                                )) {
                                  run(() => client.deleteOption(o.id));
                                }
                              },
                            )
                          : null,
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Asks for one line of text; null when cancelled or empty.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: controller.dispose,
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) =>
              Navigator.pop(context, v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controller.text.trim().isEmpty ? null : controller.text.trim(),
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
}

/// Creates an attribute, or changes [current], like `wtf attribute add` and
/// `wtf attribute edit`: name, type, and a unit group for numbers. Returns
/// the attribute, or null when cancelled.
Future<Attribute?> showAttributeDialog(
  BuildContext context, {
  Attribute? current,
}) {
  final client = context.read<Session>().client;
  final name = TextEditingController(text: current?.name ?? '');
  var datatype = current?.datatype ?? 'text';
  UnitGroup? group = current?.unitGroup;
  String? error;
  return showDialog<Attribute>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: name.dispose,
      child: StatefulBuilder(
        builder: (context, setState) {
          final number = datatype == 'integer' || datatype == 'float';
          Future<void> save() async {
            final n = name.text.trim();
            if (n.isEmpty) {
              setState(() => error = 'Enter a name');
              return;
            }
            try {
              final Attribute saved;
              if (current == null) {
                saved = await client.createAttribute(
                  name: n,
                  datatype: datatype,
                  unitGroupId: number ? group?.id : null,
                );
              } else {
                saved = await client.patchAttribute(current.id, {
                  if (n != current.name) 'name': n,
                  if (datatype != current.datatype) 'datatype': datatype,
                  if (number &&
                      group != null &&
                      group!.id != current.unitGroup?.id)
                    'unit_group': group!.id,
                });
              }
              if (context.mounted) Navigator.pop(context, saved);
            } catch (e) {
              setState(() => error = errorText(e));
            }
          }

          return AlertDialog(
            title: Text(
              current == null ? 'New attribute' : 'Edit ${current.name}',
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: datatype,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: [
                      for (final d in datatypes)
                        DropdownMenuItem(value: d, child: Text(d)),
                    ],
                    onChanged: (v) => setState(() => datatype = v ?? datatype),
                  ),
                  if (number) ...[
                    const SizedBox(height: 16),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Unit group',
                      ),
                      child: InkWell(
                        onTap: () async {
                          final g = await pickUnitGroup(
                            context,
                            noneLabel: current == null
                                ? 'None: plain numbers'
                                : null,
                          );
                          if (g != null) {
                            setState(() => group = g.id.isEmpty ? null : g);
                          }
                        },
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(group?.name ?? 'None: plain numbers'),
                            ),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: save,
                child: Text(current == null ? 'Create' : 'Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// The quantities' unit groups and their units, like `wtf unit-group list`
/// and `wtf unit-group get`.
class UnitsScreen extends StatefulWidget {
  const UnitsScreen({super.key});

  @override
  State<UnitsScreen> createState() => _UnitsScreenState();
}

class _UnitsScreenState extends State<UnitsScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    return Loader<List<UnitGroup>>(
      title: 'Units',
      load: client.unitGroups,
      builder: (context, groups, _) {
        final shown = groups
            .where(
              (g) => matchesWords('${g.name} ${g.quantity.name}', _filter.text),
            )
            .toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Units')),
          body: Readable(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _filter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.filter_list),
                      hintText: 'Filter unit groups',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final g in shown)
                        ExpansionTile(
                          key: ValueKey(g.id),
                          title: Text(g.name),
                          subtitle: Text(g.quantity.name),
                          children: [
                            FutureBuilder(
                              future: client.unitGroup(g.id),
                              builder: (context, snap) {
                                if (snap.hasError) {
                                  return EmptyNote(errorText(snap.error!));
                                }
                                if (!snap.hasData) {
                                  return const LinearProgressIndicator();
                                }
                                return Column(
                                  children: [
                                    for (final u in snap.data!.units)
                                      ListTile(
                                        dense: true,
                                        leading: SizedBox(
                                          width: 48,
                                          child: Text(u.symbol),
                                        ),
                                        title: Text(u.name),
                                        // base = value × factor + offset
                                        trailing: Text(
                                          u.isBase
                                              ? 'base unit'
                                              : '× ${u.baseFactor.toDecimal()}'
                                                    '${u.baseOffset.isZero ? '' : ' + ${u.baseOffset.toDecimal()}'}',
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                    ],
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
