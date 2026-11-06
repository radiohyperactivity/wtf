import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';
import 'item_screen.dart';

/// A stock row, like `wtf stock get`: item, location, amount, reference,
/// serial, its values and files. It can be moved, all or part (`wtf stock
/// move`), and merged into another row of its item (`wtf stock merge`).
class StockScreen extends StatelessWidget {
  const StockScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<(Stock, ClassDetail, Tree)>(
      key: ValueKey(code),
      title: 'Stock $code',
      refreshOn: client.treeChanges,
      load: () async {
        final target = await client.code(code);
        if (target is CodeGone) {
          throw const InputError(
            "This label's item, stock row or location has been deleted.",
          );
        }
        if (target is! CodeStock) {
          throw InputError('There is no stock row with the code $code.');
        }
        final stock = await client.stock(target.stock.id);
        return (
          stock,
          await client.cls(stock.item.classId),
          await client.tree(TreeKind.locations),
        );
      },
      builder: (context, data, reload) {
        final (stock, cls, locations) = data;
        final place = locations[stock.location];
        final owner = '/stock/${stock.id}';
        final write = session.canWriteItems;

        Future<void> delete() async {
          final ok = await confirmDelete(
            context,
            'this stock row',
            note:
                '${stock.item.name}, ${stock.amountText}, at ${locations.pathOf(stock.location)}.',
          );
          if (!ok || !context.mounted) return;
          try {
            await client.deleteStock(stock.id);
            if (context.mounted) {
              showMessage(context, 'Deleted stock row ${stock.code}.');
              leave(context, '/items/${stock.item.code}');
            }
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }

        Future<void> merge() async {
          final into = await showMergeDialog(context, stock, locations);
          if (into == null || !context.mounted) return;
          showMessage(
            context,
            'Merged into ${into.code} at ${locations.pathOf(into.location)}.',
          );
          // This row is gone, or has the rest.
          context.pushReplacement('/stock/${into.code}');
        }

        final files = fileTiles(
          cls,
          owner,
          stock.values,
          stock: true,
          onChanged: write ? reload : null,
          patch: (changes) => client.patchStock(stock.id, changes),
        );
        final values = valueFields(
          cls,
          stock.values,
          stock.defaulted,
          stock: true,
        );

        return Scaffold(
          appBar: AppBar(
            title: Text('${stock.item.name} · ${stock.code}'),
            actions: [
              if (write) ...[
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () async {
                    if (await context.push('/stock/${stock.code}/edit') ==
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
                          hasPhoto: stock.photo != null,
                          remove: () =>
                              client.patchStock(stock.id, {'photo': null}),
                        )) {
                          reload();
                        }
                      case 'merge':
                        merge();
                      case 'delete':
                        delete();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'photo', child: Text('Photo…')),
                    if (stock.amount != null)
                      const PopupMenuItem(
                        value: 'merge',
                        child: Text('Merge into…'),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete…'),
                    ),
                  ],
                ),
              ],
            ],
          ),
          floatingActionButton: write
              ? FloatingActionButton.extended(
                  onPressed: () async {
                    final moved = await showMoveDialog(
                      context,
                      stock,
                      locations,
                    );
                    if (moved == null || !context.mounted) return;
                    // The answer is the row at the destination: this one
                    // (moved whole), or one split off from it.
                    showMessage(
                      context,
                      'Moved to ${locations.pathOf(moved.location)}.',
                    );
                    if (moved.id == stock.id) {
                      reload();
                    } else {
                      context.pushReplacement('/stock/${moved.code}');
                    }
                  },
                  icon: const Icon(Icons.move_down),
                  label: const Text('Move'),
                )
              : null,
          body: Readable(
            child: RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  WithPhoto(
                    photo: stock.photo,
                    children: [
                      const SizedBox(height: 8),
                      Field(
                        'Item',
                        '${stock.item.name}  (${stock.item.code})',
                        onTap: () => context.push('/items/${stock.item.code}'),
                      ),
                      Field(
                        'Location',
                        locations.pathOf(stock.location),
                        onTap: place?.code == null
                            ? null
                            : () => context.push('/locations/${place!.code}'),
                      ),
                      Field('Amount', stock.amountText),
                      if (stock.reference case final r?) Field('Reference', r),
                      if (stock.serial case final s?) Field('Serial number', s),
                      Field('Code', stock.code),
                      if (values.isNotEmpty) ...[
                        const SectionTitle('Values'),
                        ...values,
                      ],
                    ],
                  ),
                  if (files.isNotEmpty) ...[
                    const SectionTitle('Files'),
                    ...files,
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

/// A location field that opens a picker: [chosen] is the location's id.
Widget _locationField(
  BuildContext context,
  Tree locations,
  String? chosen,
  Future<void> Function([String query]) choose,
) => FormField<String>(
  validator: (_) => chosen == null ? 'Choose where to' : null,
  builder: (field) => InputDecorator(
    decoration: InputDecoration(
      labelText: 'To',
      border: const OutlineInputBorder(),
      errorText: field.errorText,
    ),
    child: PickerKeys(
      open: choose,
      child: InkWell(
        onTap: choose,
        child: Row(
          children: [
            Expanded(
              child: Text(
                chosen == null ? 'Choose a location' : locations.pathOf(chosen),
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    ),
  ),
);

/// Moves a stock row, all or part, to another location, like
/// `wtf stock move`. A move never merges into another row. Returns the row
/// the stock ended up in, or null.
Future<Stock?> showMoveDialog(
  BuildContext context,
  Stock stock,
  Tree locations,
) {
  final client = context.read<Session>().client;
  final amount = TextEditingController();
  final form = GlobalKey<FormState>();
  String? target;
  return showDialog<Stock>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: amount.dispose,
      child: StatefulBuilder(
        builder: (context, setState) {
          Future<void> chooseTarget([String query = '']) async {
            final id = await pickNode(
              context,
              TreeKind.locations,
              title: 'Move to',
              forUse: true,
              exclude: {stock.location},
              query: query,
            );
            if (id != null) setState(() => target = id);
          }

          return AlertDialog(
            title: Text('Move ${stock.item.name}'),
            content: SizedBox(
              width: 420,
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Now at ${locations.pathOf(stock.location)}: ${stock.amountText}.',
                    ),
                    const SizedBox(height: 16),
                    _locationField(context, locations, target, chooseTarget),
                    if (stock.amount != null) ...[
                      const SizedBox(height: 16),
                      AmountField(
                        controller: amount,
                        unit: stock.item.unit,
                        emptyMeans: 'all of it',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (!form.currentState!.validate()) return;
                  try {
                    final moved = await client.moveStock(
                      stock.id,
                      target!,
                      amount: AmountField.parse(amount, stock.item.unit),
                    );
                    if (context.mounted) Navigator.pop(context, moved);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Move'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// What differs between stock rows [a] and [b], as the server finds it:
/// "reference", "serial", "photo", and `values.NAME` for each value one
/// has and the other hasn't, or has with another value.
List<String> stockDifferences(Stock a, Stock b) => [
  if (a.reference != b.reference) 'reference',
  if (a.serial != b.serial) 'serial',
  if (a.photo?.hash != b.photo?.hash) 'photo',
  for (final name in {...a.values.keys, ...b.values.keys})
    if (a.values[name] != b.values[name]) 'values.$name',
];

/// Merges all of a stock row, or part of it, into another counted row of
/// its item, like `wtf stock merge`. Where the two differ, the user says
/// which row's to keep for each difference, as the server asks. Returns
/// the row merged into, or null.
Future<Stock?> showMergeDialog(
  BuildContext context,
  Stock stock,
  Tree locations,
) async {
  final client = context.read<Session>().client;
  final ItemDetail item;
  final ClassDetail cls;
  try {
    item = await client.item(stock.item.id);
    cls = await client.cls(item.cls.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final others = [
    for (final s in item.stock)
      if (s.id != stock.id && s.amount != null) s,
  ];
  if (others.isEmpty) {
    showMessage(
      context,
      '${item.name} has no other counted stock row to merge into.',
    );
    return null;
  }
  final amount = TextEditingController();
  final form = GlobalKey<FormState>();
  Stock? into = others.length == 1 ? others.single : null;
  // For each difference, the row whose to keep: "from" (this one) or
  // "into".
  final keep = <String, String>{};
  String? error;

  String shown(String difference, Stock s) {
    final text = switch (difference) {
      'reference' => s.reference,
      'serial' => s.serial,
      'photo' => s.photo == null ? null : 'a photo',
      _ => formatValue(
        cls.attribute(difference.substring('values.'.length)),
        s.values[difference.substring('values.'.length)],
      ),
    };
    return text == null || text.isEmpty ? 'none' : text;
  }

  String label(String difference) => switch (difference) {
    'reference' => 'Reference',
    'serial' => 'Serial number',
    'photo' => 'Photo',
    _ => difference.substring('values.'.length),
  };

  return showDialog<Stock>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: amount.dispose,
      child: StatefulBuilder(
        builder: (context, setState) {
          final target = into;
          final differences = target == null
              ? const <String>[]
              : stockDifferences(stock, target);
          return AlertDialog(
            title: Text('Merge ${stock.code} into another row'),
            content: SizedBox(
              width: 520,
              child: Form(
                key: form,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'This row: ${stock.amountText} at ${locations.pathOf(stock.location)}.',
                      ),
                      const SizedBox(height: 8),
                      RadioGroup<String>(
                        groupValue: target?.id,
                        onChanged: (id) => setState(() {
                          into = others.firstWhere((s) => s.id == id);
                          keep.clear();
                        }),
                        child: Column(
                          children: [
                            for (final s in others)
                              RadioListTile<String>(
                                contentPadding: EdgeInsets.zero,
                                value: s.id,
                                title: Text(
                                  '${s.code}  ${locations.pathOf(s.location)}',
                                ),
                                subtitle: Text(
                                  [
                                    s.amountText,
                                    stockMarks(s),
                                  ].where((t) => t.isNotEmpty).join(' · '),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      AmountField(
                        controller: amount,
                        unit: stock.item.unit,
                        emptyMeans: 'all of it',
                      ),
                      if (target != null && differences.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'The rows differ. Which to keep?',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        for (final d in differences)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(label(d)),
                                const SizedBox(height: 4),
                                SegmentedButton<String>(
                                  segments: [
                                    ButtonSegment(
                                      value: 'from',
                                      label: Text(
                                        '${stock.code}: ${shown(d, stock)}',
                                      ),
                                    ),
                                    ButtonSegment(
                                      value: 'into',
                                      label: Text(
                                        '${target.code}: ${shown(d, target)}',
                                      ),
                                    ),
                                  ],
                                  selected: {keep[d] ?? 'into'},
                                  onSelectionChanged: (s) =>
                                      setState(() => keep[d] = s.single),
                                ),
                              ],
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
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: target == null
                    ? null
                    : () async {
                        if (!form.currentState!.validate()) return;
                        final values = <String, String>{
                          for (final d in differences)
                            if (d.startsWith('values.'))
                              d.substring('values.'.length): keep[d] ?? 'into',
                        };
                        final resolve = <String, Object>{
                          for (final d in differences)
                            if (!d.startsWith('values.')) d: keep[d] ?? 'into',
                          if (values.isNotEmpty) 'values': values,
                        };
                        try {
                          final merged = await client.mergeStock(
                            stock.id,
                            target.id,
                            amount: AmountField.parse(amount, stock.item.unit),
                            resolve: resolve.isEmpty ? null : resolve,
                          );
                          if (context.mounted) Navigator.pop(context, merged);
                        } catch (e) {
                          setState(() => error = errorText(e));
                        }
                      },
                child: const Text('Merge'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
