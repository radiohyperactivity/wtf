import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/form_keys.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';

/// Adds a stock row (of [itemId] and at [locationId], when given), or edits
/// the row with [code]. Like `wtf stock add` and `wtf stock edit`: item,
/// location and amount (empty: uncounted), then the values of the class's
/// stock attributes.
class StockFormScreen extends StatelessWidget {
  const StockFormScreen({super.key, this.code, this.itemId, this.locationId});

  final String? code;
  final String? itemId;
  final String? locationId;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final code = this.code;
    return Loader<(Stock?, ItemDetail?, Tree)>(
      title: code == null ? 'Add stock' : 'Edit stock',
      load: () async {
        final locations = await client.tree(TreeKind.locations);
        if (code == null) {
          return (
            null,
            itemId == null ? null : await client.item(itemId!),
            locations,
          );
        }
        final target = await client.code(code);
        if (target is! CodeStock) {
          throw InputError('There is no stock row with the code $code.');
        }
        final stock = await client.stock(target.stock.id);
        return (stock, await client.item(stock.item.id), locations);
      },
      builder: (context, data, _) => _StockForm(
        stock: data.$1,
        item: data.$2,
        locations: data.$3,
        locationId: locationId,
      ),
    );
  }
}

class _StockForm extends StatefulWidget {
  const _StockForm({
    required this.stock,
    required this.item,
    required this.locations,
    this.locationId,
  });

  final Stock? stock;
  final ItemDetail? item;
  final Tree locations;
  final String? locationId;

  @override
  State<_StockForm> createState() => _StockFormState();
}

class _StockFormState extends State<_StockForm> {
  final _form = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: widget.stock?.amount == null
        ? ''
        : formatNumber(widget.stock!.amount!),
  );
  late ItemDetail? _item = widget.item;

  // New stock's location: the one the form was opened for (from a
  // location's screen, say), else the one this session last added stock to
  // or made, whichever came later.
  late String? _locationId =
      widget.stock?.location ??
      _usable(widget.locationId) ??
      context.read<Session>().recent.stockLocation((id) => _usable(id) != null);
  final _amountFocus = FocusNode();
  List<ValueInput> _inputs = [];
  bool _loading = false;
  Object? _loadError;
  bool _busy = false;

  ApiClient get _client => context.read<Session>().client;
  bool get _editing => widget.stock != null;

  /// A location stock can be at: not a container.
  String? _usable(String? id) =>
      id != null && widget.locations[id]?.container == false ? id : null;

  @override
  void initState() {
    super.initState();
    if (_item != null) _loadItem();
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    for (final i in _inputs) {
      i.dispose();
    }
    super.dispose();
  }

  /// The inputs of the stock attributes of the item's class.
  Future<void> _loadItem() async {
    final item = _item!;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final cls = await _client.cls(item.cls.id);
      final stock = widget.stock;
      final inputs = valueInputs(
        cls,
        stock: true,
        values: stock?.values ?? const {},
        defaulted: stock?.defaulted ?? const {},
      );
      if (!mounted || item != _item) return;
      final old = _inputs;
      setState(() => _inputs = inputs);
      // The old fields are still drawn once more.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final i in old) {
          i.dispose();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseItem([String query = '']) async {
    final found = await pickItem(context, query: query);
    if (found == null) return;
    try {
      final item = await _client.item(found.id);
      setState(() => _item = item);
      _loadItem();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _chooseLocation([String query = '']) async {
    final id = await pickNode(
      context,
      TreeKind.locations,
      query: query,
      title: 'Location',
      forUse: true,
    );
    if (id == null) return;
    setState(() => _locationId = id);
    // On to the amount, as Tab would have gone.
    if (_item != null &&
        _item!.counting != Counting.none &&
        _amount.text.isEmpty) {
      _amountFocus.requestFocus();
    }
  }

  /// Saves; with [another], new stock is followed by the form again, for
  /// more of the same item at the same place.
  Future<void> _save({bool another = false}) async {
    if (_busy || _loading) return;
    final item = _item;
    final location = _locationId;
    if (item == null || location == null) {
      showError(
        context,
        InputError(item == null ? 'Choose an item.' : 'Choose a location.'),
      );
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      // As its class counts its stock: no amount when it doesn't.
      final amount = item.counting == Counting.none
          ? null
          : AmountField.parse(_amount, item.unit);
      final stock = widget.stock;
      if (stock == null) {
        final created = await _client.createStock(
          itemId: item.id,
          locationId: location,
          amount: amount,
          values: newValues(_inputs),
        );
        if (mounted) {
          context.read<Session>().recent.stockAdded(location);
          showMessage(
            context,
            'Added ${item.name} at ${widget.locations.pathOf(location)}.',
          );
          if (another) {
            // The item stays if the form was opened for it (from its
            // screen); from a location's, the next item is chosen.
            context.pushReplacement(
              Uri(
                path: '/stock/new',
                queryParameters: {
                  if (widget.item != null) 'item': item.id,
                  'location': location,
                },
              ).toString(),
            );
          } else {
            context.pop(created);
          }
        }
        return;
      }
      final changes = valueChanges(_inputs)
        ..addAll({
          if (location != stock.location) 'location': location,
          if (!sameNumber(amount, stock.amount)) 'amount': amount,
        });
      if (changes.isNotEmpty) await _client.patchStock(stock.id, changes);
      if (mounted) {
        showMessage(context, changes.isEmpty ? 'No changes.' : 'Saved.');
        context.pop(changes.isNotEmpty);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _editing ? 'Edit stock ${widget.stock!.code}' : 'Add stock',
        ),
        actions: [
          if (!_editing)
            AnotherButton(
              label: 'Add and add another',
              onPressed: _busy ? null : _saveAnother,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_editing ? 'Save' : 'Add'),
            ),
          ),
        ],
      ),
      body: Readable(
        maxWidth: 640,
        child: FormKeys(
          save: _save,
          saveAnother: _editing ? null : _saveAnother,
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // The item of an existing row is changed with care elsewhere
                // (as in the CLI, where `stock set --item` does it).
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Item',
                    border: OutlineInputBorder(),
                  ),
                  child: PickerKeys(
                    open: _editing || widget.item != null ? null : _chooseItem,
                    child: InkWell(
                      onTap: _editing || widget.item != null
                          ? null
                          : _chooseItem,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              item == null
                                  ? 'Choose an item'
                                  : '${item.name}  (${item.code})',
                            ),
                          ),
                          if (!_editing && widget.item == null)
                            const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                  ),
                  child: PickerKeys(
                    open: _chooseLocation,
                    child: InkWell(
                      onTap: _chooseLocation,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _locationId == null
                                  ? 'Choose a location'
                                  : widget.locations.pathOf(_locationId),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
                // As its class counts its stock: no amount when it doesn't,
                // one that must be given when it requires it.
                if (item != null && item.counting != Counting.none) ...[
                  const SizedBox(height: 16),
                  AmountField(
                    controller: _amount,
                    unit: item.unit,
                    focusNode: _amountFocus,
                    required: item.counting == Counting.required,
                    // Ready to type, when the item and place are known.
                    autofocus: !_editing && _locationId != null,
                    onSubmitted: lastTyped(_inputs) == null ? _save : null,
                  ),
                ],
                if (_loadError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    errorText(_loadError!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _loadItem,
                    child: const Text('Try again'),
                  ),
                ],
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                if (_inputs.isNotEmpty) ...[
                  const SectionTitle('Stock values'),
                  for (final i in _inputs)
                    Padding(
                      key: ValueKey(i.attribute.name),
                      padding: const EdgeInsets.only(top: 12),
                      child: ValueField(
                        i,
                        onSubmitted: identical(i, lastTyped(_inputs))
                            ? _save
                            : null,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _saveAnother() => _save(another: true);
}
