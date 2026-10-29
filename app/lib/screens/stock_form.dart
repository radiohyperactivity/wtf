import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';

/// Adds a stock row (of [itemId] and at [locationId], when given), or edits
/// the row with [code]. Like `wtf stock add` and `wtf stock edit`: item,
/// location, quantity (empty: uncounted), then the per-unit values.
class StockFormScreen extends StatelessWidget {
  const StockFormScreen({
    super.key,
    this.code,
    this.itemId,
    this.locationId,
    this.then,
  });

  final String? code;
  final String? itemId;
  final String? locationId;

  /// Where to go after adding, instead of back (after a new item, its screen).
  final String? then;

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
        then: then,
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
    this.then,
  });

  final Stock? stock;
  final ItemDetail? item;
  final Tree locations;
  final String? locationId;
  final String? then;

  @override
  State<_StockForm> createState() => _StockFormState();
}

class _StockFormState extends State<_StockForm> {
  final _form = GlobalKey<FormState>();
  final _quantity = MeasureController();
  late ItemDetail? _item = widget.item;
  late String? _locationId =
      widget.stock?.location ?? _usable(widget.locationId);
  UnitChoice? _units;
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
    final stock = widget.stock;
    if (stock != null && stock.quantity != null) {
      // The quantity as shown, which reads back the same ("1.2 m").
      _quantity.text = stock.quantityText;
    }
    if (_item != null) _loadItem();
  }

  @override
  void dispose() {
    _quantity.dispose();
    for (final i in _inputs) {
      i.dispose();
    }
    super.dispose();
  }

  /// The units of the item's quantity and the inputs of its per-unit values.
  Future<void> _loadItem() async {
    final item = _item!;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final unit = item.unit;
      final units = unit == null ? null : await _client.unitChoice(unit);
      final cls = await _client.cls(item.cls.id);
      final current = widget.stock == null
          ? <String, String>{}
          : ownValues(widget.stock!.values);
      final inputs = await loadValueInputs(
        _client,
        cls.attributes,
        perUnit: true,
        current: current,
      );
      if (!mounted || item != _item) return;
      final old = _inputs;
      setState(() {
        _units = units;
        final stock = widget.stock;
        if (stock?.quantity != null && item.id == stock!.item.id) {
          // The number in the field and its unit in the menu: "1.2", "m".
          _quantity.show(stock.quantityText, units);
        } else {
          _quantity.plainIn = null; // the new item's own unit
        }
        _inputs = inputs;
      });
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
    if (id != null) setState(() => _locationId = id);
  }

  /// Whether [quantity] (null: uncounted) is the [old] one, whatever unit it
  /// was typed in.
  static bool _sameQuantity(Decimal? quantity, num? old) =>
      quantity == null || old == null
      ? quantity == null && old == null
      : Rational.tryParse(quantity.text) == Rational.fromNum(old);

  Future<void> _save() async {
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
      final quantity = QuantityField.parse(_quantity, _units);
      final stock = widget.stock;
      if (stock == null) {
        final created = await _client.createStock(
          itemId: item.id,
          locationId: location,
          quantity: quantity,
          values: {
            for (final i in _inputs)
              if (i.text.isNotEmpty) i.attribute.id: i.parse(),
          },
        );
        if (mounted) {
          showMessage(
            context,
            'Added ${item.name} at ${widget.locations.pathOf(location)}.',
          );
          final then = widget.then;
          if (then != null && then.startsWith('/') && !then.startsWith('//')) {
            context.pushReplacement(then);
          } else {
            context.pop(created);
          }
        }
        return;
      }
      final saved = <String>[];
      final changes = <String, Object?>{
        if (location != stock.location) 'location': location,
        if (!_sameQuantity(quantity, stock.quantity)) 'quantity': quantity,
      };
      if (changes.isNotEmpty) {
        await _client.patchStock(stock.id, changes);
        saved.addAll(changes.keys);
      }
      final all = await saveValues(
        _inputs,
        set: (a, v) => _client.setStockValue(stock.id, a, v),
        remove: (a) => _client.deleteStockValue(stock.id, a),
        savedBefore: saved,
      );
      if (mounted) {
        showMessage(
          context,
          all.isEmpty ? 'No changes.' : 'Saved: ${all.join(', ')}.',
        );
        context.pop(all.isNotEmpty);
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
                    onTap: _editing || widget.item != null ? null : _chooseItem,
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
              const SizedBox(height: 16),
              if (item != null && !_loading)
                QuantityField(controller: _quantity, units: _units),
              if (_loadError != null) ...[
                const SizedBox(height: 16),
                Text(
                  errorText(_loadError!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                const SectionTitle('Per-unit values'),
                for (final i in _inputs)
                  Padding(
                    key: ValueKey(i.attribute.id),
                    padding: const EdgeInsets.only(top: 12),
                    child: ValueField(i),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
