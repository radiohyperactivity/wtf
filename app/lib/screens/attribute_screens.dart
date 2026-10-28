import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/restore.dart';
import '../widgets/value_fields.dart';

String _describe(Attribute a) => [
  a.datatype,
  if (a.unit case final u?) unitLabel(u, lock: a.unitLock),
].join(' · ');

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
                if (a.unit case final u?) ...[
                  Field('Unit', unitLabel(u), note: u.quantity.name),
                  Field(
                    'Unit lock',
                    a.unitLock
                        ? 'on: always shown in ${u.symbol}'
                        : 'off: shown in the unit of ${u.familyName} that fits best',
                  ),
                ],
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
/// `wtf attribute edit`: name, type, and a unit for numbers, with Unit lock.
/// Picking a unit sets the type to its quantity's. Returns the attribute, or
/// null when cancelled.
Future<Attribute?> showAttributeDialog(
  BuildContext context, {
  Attribute? current,
}) {
  final client = context.read<Session>().client;
  final name = TextEditingController(text: current?.name ?? '');
  var datatype = current?.datatype ?? 'text';
  Unit? unit = current?.unit;
  var unitLock = current?.unitLock ?? false;
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
                  unitId: number ? unit?.id : null,
                  unitLock: number && unit != null && unitLock,
                );
              } else {
                saved = await client.patchAttribute(current.id, {
                  if (n != current.name) 'name': n,
                  if (datatype != current.datatype) 'datatype': datatype,
                  if (number && unit != null && unit!.id != current.unit?.id)
                    'unit': unit!.id,
                  if (number && unit != null && unitLock != current.unitLock)
                    'unit_lock': unitLock,
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
                  // A unit can be changed (to another of its quantity), but
                  // not added or removed, as in the CLI.
                  if (number && (current == null || current.unit != null)) ...[
                    const SizedBox(height: 16),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Unit'),
                      child: InkWell(
                        onTap: () async {
                          final picked = await pickUnit(
                            context,
                            noneLabel: current == null
                                ? 'None: plain numbers'
                                : null,
                            quantityId: current?.unit?.quantity.id,
                          );
                          if (picked == null) return;
                          setState(() {
                            unit = picked.unit;
                            if (unit != null) {
                              datatype = unit!.quantity.datatype;
                            }
                          });
                        },
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                unit == null
                                    ? 'None: plain numbers'
                                    : unitLabel(unit!),
                              ),
                            ),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                    if (unit != null)
                      UnitLockSwitch(
                        unit: unit!,
                        value: unitLock,
                        onChanged: (v) => setState(() => unitLock = v),
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

/// The units by quantity, then by family, like `wtf unit-family list`:
/// Length, with Metric length and Imperial length under it. Accounts that
/// may change the model turn quantities and families on and off here; what
/// is off can't be chosen as a unit (TENANTS.md, decision 16).
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

  Widget _unitTile(Unit u) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 48, right: 16),
    leading: SizedBox(width: 72, child: Text(u.symbol)),
    title: Text(u.name),
    // base = value × factor + offset
    trailing: Text(
      u.baseFactor == Rational(BigInt.one) && u.baseOffset.isZero
          ? 'base unit'
          : '× ${u.baseFactor.toDecimal()}'
                '${u.baseOffset.isZero ? '' : ' + ${u.baseOffset.toDecimal()}'}',
    ),
  );

  /// Turns a quantity or family on or off (null: back to its default);
  /// the server refuses while something uses its units, and says what.
  Future<void> _setAvailable(
    Future<void> Function() change,
    Future<void> Function() reload,
  ) async {
    try {
      await change();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    await reload();
  }

  /// A switch for a quantity's or family's availability, and a way back to
  /// the default once chosen; only "Off" for others.
  Widget _availability(
    Availability a, {
    required bool write,
    bool enabled = true,
    required Future<void> Function(bool? available) set,
  }) {
    if (!write) {
      return a.available ? const SizedBox.shrink() : const Text('Off');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (a.choice != null && a.global)
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip:
                'Back to the default (${a.defaultAvailable ? 'on' : 'off'})',
            onPressed: () => set(null),
          ),
        Switch(value: a.available, onChanged: enabled ? (v) => set(v) : null),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final write = context.watch<Session>().canWriteModel;
    return Loader<(List<Quantity>, List<UnitFamily>)>(
      title: 'Units',
      load: () async =>
          (await client.quantities(), await client.unitFamilies()),
      builder: (context, data, reload) {
        final (quantities, families) = data;
        // The quantities as the inventory has them (on or off).
        final quantity = {for (final q in quantities) q.id: q};
        // The server lists families by quantity, so grouping keeps its order.
        final byQuantity = <String, (Quantity, List<UnitFamily>)>{};
        for (final f in families) {
          if (matchesWords(
            '${f.name} ${f.quantity.name} ${f.units.map((u) => '${u.symbol} ${u.name}').join(' ')}',
            _filter.text,
          )) {
            byQuantity
                .putIfAbsent(
                  f.quantity.id,
                  () => (quantity[f.quantity.id] ?? f.quantity, []),
                )
                .$2
                .add(f);
          }
        }
        // While filtering, everything that matches is shown open.
        final filtering = _filter.text.trim().isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Units'),
            actions: [
              if (context.watch<Session>().canWriteModel)
                TextButton.icon(
                  onPressed: () => importUnitFile(context, reload),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import'),
                ),
            ],
          ),
          body: Readable(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _filter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.filter_list),
                      hintText: 'Filter quantities, unit families and units',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final (q, fs) in byQuantity.values)
                        ExpansionTile(
                          key: ValueKey('q${q.id} $filtering'),
                          initiallyExpanded: filtering,
                          title: Text(q.name),
                          subtitle: Text(
                            [
                              if (q.baseSymbol.isNotEmpty) 'in ${q.baseSymbol}',
                              ...fs.map((f) => f.name),
                            ].join(' · '),
                          ),
                          trailing: _availability(
                            q,
                            write: write,
                            set: (v) => _setAvailable(
                              () => client.setQuantityAvailable(q.id, v),
                              reload,
                            ),
                          ),
                          children: [
                            for (final f in fs)
                              ExpansionTile(
                                key: ValueKey('f${f.id} $filtering'),
                                initiallyExpanded: filtering,
                                tilePadding: const EdgeInsets.only(
                                  left: 32,
                                  right: 16,
                                ),
                                title: Text(f.name),
                                subtitle: Text(unitSymbols(f.units)),
                                // A family of a quantity that is off stays off.
                                trailing: _availability(
                                  f,
                                  write: write,
                                  enabled: q.available,
                                  set: (v) => _setAvailable(
                                    () => client.setFamilyAvailable(f.id, v),
                                    reload,
                                  ),
                                ),
                                children: [
                                  for (final u in f.units) _unitTile(u),
                                ],
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

/// A unit file chosen to import: its file name and its text.
typedef UnitFile = ({String name, String text});

/// Lets the user choose a unit file; null when cancelled. Tests replace it.
Future<UnitFile?> Function() pickUnitFile = () async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choose a unit file',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (files.isEmpty) return null;
  final bytes = await files.first.readAsBytes();
  return (
    name: files.first.name,
    text: utf8.decode(bytes, allowMalformed: true),
  );
};

/// Imports a unit file (seed/units-format.md), like `wtf unit import`: a
/// dry run first, which shows what would be added, what is there already
/// and any conflicts; then, when asked, the import. [reload] shows the new
/// units.
Future<void> importUnitFile(
  BuildContext context,
  Future<void> Function() reload,
) async {
  final client = context.read<Session>().client;
  final UnitFile? file;
  try {
    file = await pickUnitFile();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (file == null || !context.mounted) return;
  String title = file.name;
  try {
    final named = (jsonDecode(file.text) as Map)['name'];
    if (named is String && named.trim().isNotEmpty) {
      title = '${named.trim()} (${file.name})';
    }
  } on Object {
    showError(context, InputError('${file.name} is not JSON.'));
    return;
  }
  final UnitImport preview;
  try {
    preview = await client.importUnits(file.text, dryRun: true);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => _UnitImportDialog(title: title, report: preview),
  );
  if (go != true || !context.mounted) return;
  try {
    final done = await client.importUnits(file.text);
    if (!context.mounted) return;
    if (!done.applied) {
      // Something changed since the dry run.
      await showDialog<void>(
        context: context,
        builder: (context) => _UnitImportDialog(title: title, report: done),
      );
      return;
    }
    showMessage(
      context,
      'Imported ${_count(done.units.length, 'unit')}, '
      '${_count(done.families.length, 'unit family', 'unit families')} and '
      '${_count(done.quantities.length, 'quantity', 'quantities')}.',
    );
    await reload();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

String _count(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// What an import would add (or the conflicts that stop it), with Import
/// when there is something to import and nothing in the way.
class _UnitImportDialog extends StatelessWidget {
  const _UnitImportDialog({required this.title, required this.report});

  final String title;
  final UnitImport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = report;
    final byFamily = <String, List<String>>{};
    for (final (family, symbol) in r.units) {
      byFamily.putIfAbsent(family, () => []).add(symbol);
    }
    Widget line(String label, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: text),
          ],
        ),
      ),
    );
    final blocked = r.conflicts.isNotEmpty;
    return AlertDialog(
      title: Text('Import $title'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (blocked) ...[
                Text(
                  'Nothing can be imported until these are fixed in the file:',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                for (final (where, message) in r.conflicts)
                  line(where, message),
                const SizedBox(height: 16),
              ],
              if (r.nothingNew)
                const Text('Everything in this file is there already.')
              else ...[
                Text(blocked ? 'It would add:' : 'This adds:'),
                if (r.quantities.isNotEmpty)
                  line('Quantities', r.quantities.join(', ')),
                if (r.families.isNotEmpty)
                  line('Unit families', r.families.join(', ')),
                for (final MapEntry(:key, :value) in byFamily.entries)
                  line('Units in $key', value.join(', ')),
              ],
              if (r.existing > 0 && !r.nothingNew)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${_count(r.existing, 'thing')} in the file '
                    '${r.existing == 1 ? 'is' : 'are'} there already, and '
                    '${r.existing == 1 ? 'stays' : 'stay'} as '
                    '${r.existing == 1 ? 'it is' : 'they are'}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            blocked || r.nothingNew || r.applied ? 'Close' : 'Cancel',
          ),
        ),
        if (!blocked && !r.nothingNew && !r.applied)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import'),
          ),
      ],
    );
  }
}
