import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/attachments.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/restore.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';
import 'item_screen.dart';

/// A stock row, like `wtf stock get`: item, location, quantity and its
/// per-unit values. It can be moved, all or part (`wtf stock move`).
class StockScreen extends StatelessWidget {
  const StockScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<(Stock, Tree, String)>(
      key: ValueKey(code),
      title: 'Stock $code',
      refreshOn: client.treeChanges,
      load: () async {
        final target = await client.code(code);
        if (target is! CodeStock) {
          throw InputError('There is no stock row with the code $code.');
        }
        final stock = await client.stock(target.stock.id);
        return (
          stock,
          await client.tree(TreeKind.locations),
          (await client.locationPaths([stock.location]))[stock.location]!,
        );
      },
      builder: (context, data, reload) {
        final (stock, locations, path) = data;
        final place = locations[stock.location];
        // A deleted row can only be looked at, and restored.
        final write = session.canWriteItems && !stock.deleted;

        Future<void> delete() async {
          final ok = await confirm(
            context,
            title: 'Delete this stock row?',
            message:
                '${stock.item.name}, ${stock.quantityText}, at ${locations.pathOf(stock.location)}.',
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

        return Scaffold(
          appBar: AppBar(
            title: Text('${stock.item.name} · ${stock.code}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'History',
                onPressed: () => context.push(
                  '/history/stock/${stock.id}?title=${Uri.encodeComponent('${stock.item.name} ${stock.code}')}',
                ),
              ),
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
                  onPressed: () async {
                    final moved = await showMoveDialog(
                      context,
                      stock,
                      locations,
                    );
                    if (moved == null || !context.mounted) return;
                    // The answer is the row at the destination: this one
                    // (moved whole), or another one, split off or merged into.
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
                  if (stock.deleted)
                    DeletedBanner(
                      kind: RestoreKind.stock,
                      id: stock.id,
                      label: 'stock row ${stock.code}',
                      canRestore: session.canWriteItems,
                      onRestored: reload,
                      mergedInto: stock.mergedInto,
                      onOpenMerged: () =>
                          context.pushReplacement('/stock/${stock.mergedInto}'),
                    ),
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
                        path,
                        onTap: place?.code == null
                            ? null
                            : () => context.push('/locations/${place!.code}'),
                      ),
                      Field('Quantity', stock.quantityText),
                      Field('Code', stock.code),
                      if (stock.values.isNotEmpty) ...[
                        const SectionTitle('Values'),
                        ...valueFields(stock.values),
                      ],
                      MissingNote(stock.missing.map((m) => m.name).toList()),
                    ],
                  ),
                  AttachmentList(
                    stock.attachments,
                    ownerPath: '/stock/${stock.id}',
                    photo: stock.photo,
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

/// Moves a stock row, all or part, to another location, like
/// `wtf stock move`. Returns the row the stock ended up in, or null.
Future<Stock?> showMoveDialog(
  BuildContext context,
  Stock stock,
  Tree locations,
) async {
  final client = context.read<Session>().client;
  UnitChoice? units;
  try {
    final unit = stock.item.unit;
    units = unit == null ? null : await client.unitChoice(unit);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final quantity = MeasureController();
  final form = GlobalKey<FormState>();
  String? target;
  return showDialog<Stock>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: quantity.dispose,
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
                      'Now at ${locations.pathOf(stock.location)}: ${stock.quantityText}.',
                    ),
                    const SizedBox(height: 16),
                    FormField<String>(
                      validator: (_) =>
                          target == null ? 'Choose where to' : null,
                      builder: (field) => InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'To',
                          border: const OutlineInputBorder(),
                          errorText: field.errorText,
                        ),
                        child: PickerKeys(
                          open: chooseTarget,
                          child: InkWell(
                            onTap: chooseTarget,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    target == null
                                        ? 'Choose a location'
                                        : locations.pathOf(target),
                                  ),
                                ),
                                const Icon(Icons.arrow_drop_down),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (stock.quantity != null) ...[
                      const SizedBox(height: 16),
                      QuantityField(
                        controller: quantity,
                        units: units,
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
                      quantity: QuantityField.parse(quantity, units),
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
