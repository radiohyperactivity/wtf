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

/// Adds an item (in [classId], if given), or edits the item with [code].
/// Like `wtf item add` and `wtf item edit`: class, name, then the class's
/// attributes. A new item's first stock row is on the same form, and saved
/// with it, in one request: where it is, how many, and its stock values
/// (decision 107); how many as its class counts its stock (decision 110).
class ItemFormScreen extends StatelessWidget {
  const ItemFormScreen({super.key, this.code, this.classId});

  final String? code;
  final String? classId;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final code = this.code;
    return Loader<(ItemDetail?, Tree, Tree?)>(
      title: code == null ? 'New item' : 'Edit item',
      load: () async {
        final classes = await client.tree(TreeKind.classes);
        if (code == null) {
          return (null, classes, await client.tree(TreeKind.locations));
        }
        final target = await client.code(code);
        if (target is! CodeItem) {
          throw InputError('There is no item with the code $code.');
        }
        return (target.item, classes, null);
      },
      builder: (context, data, _) => _ItemForm(
        item: data.$1,
        classes: data.$2,
        locations: data.$3,
        classId: classId,
      ),
    );
  }
}

class _ItemForm extends StatefulWidget {
  const _ItemForm({
    required this.item,
    required this.classes,
    required this.locations,
    this.classId,
  });

  final ItemDetail? item;
  final Tree classes;

  /// For a new item's stock; null when editing.
  final Tree? locations;
  final String? classId;

  @override
  State<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<_ItemForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  final _amount = TextEditingController();
  final _nameFocus = FocusNode();
  final _amountFocus = FocusNode();

  // A new item's class: the one the form was opened for (from a class's
  // screen, say), else the one this session last added an item in or made,
  // whichever came later.
  late String? _classId =
      widget.item?.cls.id ??
      _usable(widget.classId) ??
      context.read<Session>().recent.itemClass((id) => _usable(id) != null);

  // A new item's stock: whether to add it, as for the last item this
  // session added; and where, as for new stock on its own form.
  late bool _addStock = context.read<Session>().recent.addStock;
  late String? _locationId = context.read<Session>().recent.stockLocation(
    (id) => _usableLocation(id) != null,
  );

  ClassDetail? _class;
  List<ValueInput> _inputs = [];
  List<ValueInput> _stockInputs = [];
  bool _loadingValues = false;
  Object? _valuesError;
  bool _busy = false;

  ApiClient get _client => context.read<Session>().client;
  bool get _editing => widget.item != null;

  /// A class items can be in: not a container.
  String? _usable(String? id) =>
      id != null && widget.classes[id]?.container == false ? id : null;

  /// A location stock can be at: not a container.
  String? _usableLocation(String? id) =>
      id != null && widget.locations?[id]?.container == false ? id : null;

  @override
  void initState() {
    super.initState();
    if (_classId != null) _loadValues();
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _nameFocus.dispose();
    _amountFocus.dispose();
    for (final i in [..._inputs, ..._stockInputs]) {
      i.dispose();
    }
    super.dispose();
  }

  /// The attribute inputs of the chosen class: the item's, and for a new
  /// item its stock row's. Text typed for an attribute the new class has
  /// too is kept.
  Future<void> _loadValues() async {
    final classId = _classId;
    if (classId == null) return;
    setState(() {
      _loadingValues = true;
      _valuesError = null;
    });
    try {
      Map<String, String> typed(List<ValueInput> inputs) => {
        for (final i in inputs) i.attribute.name: i.controller.text,
      };
      void keep(List<ValueInput> inputs, Map<String, String> typed) {
        for (final i in inputs) {
          final text = typed[i.attribute.name];
          if (text != null) i.controller.text = text;
        }
      }

      final typedItem = typed(_inputs);
      final typedStock = typed(_stockInputs);
      final cls = await _client.cls(classId);
      final item = widget.item;
      final inputs = valueInputs(
        cls,
        stock: false,
        values: item?.values ?? const {},
        defaulted: item?.defaulted ?? const {},
      );
      final stockInputs = _editing
          ? <ValueInput>[]
          : valueInputs(cls, stock: true);
      keep(inputs, typedItem);
      keep(stockInputs, typedStock);
      if (!mounted || classId != _classId) return;
      final old = [..._inputs, ..._stockInputs];
      setState(() {
        _class = cls;
        _inputs = inputs;
        _stockInputs = stockInputs;
      });
      // The old fields are still drawn once more.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final i in old) {
          i.dispose();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _valuesError = e);
    } finally {
      if (mounted) setState(() => _loadingValues = false);
    }
  }

  Future<void> _chooseClass([String query = '']) async {
    final id = await pickNode(
      context,
      TreeKind.classes,
      title: 'Class',
      forUse: true,
      query: query,
    );
    if (id == null || id == _classId) return;
    setState(() => _classId = id);
    _loadValues();
    // On to the name, as Tab would have gone.
    if (!_editing && _name.text.isEmpty) _nameFocus.requestFocus();
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
    if (_counted && _amount.text.isEmpty) _amountFocus.requestFocus();
  }

  /// The values the item has that the chosen class has no attribute for:
  /// moving it there removes them.
  List<String> get _dropped {
    final item = widget.item;
    final cls = _class;
    if (item == null || cls == null || cls.id == item.cls.id) return const [];
    return [
      for (final name in item.values.keys)
        if (cls.attribute(name)?.onStock != false) name,
    ];
  }

  /// How the chosen class counts its items' stock; the default while it
  /// loads.
  StockRule get _rule => _class?.stock ?? const StockRule();

  /// Whether the stock row has an amount field: its class counts its stock.
  bool get _counted => _rule.counting != Counting.none;

  /// Whether the form makes a stock row with the new item.
  bool get _withStock => !_editing && _addStock;

  /// The field Enter saves in: the last one typed into, of the parts in use
  /// (a list to choose from takes Enter for choosing). The amount's
  /// controller stands for the amount, the name's for the name.
  Object get _lastField {
    if (_withStock) {
      final stock = lastTyped(_stockInputs) ?? (_counted ? _amount : null);
      if (stock != null) return stock;
    }
    return lastTyped(_inputs) ?? _name;
  }

  /// Saves; with [another], the form for the next new item follows instead
  /// of the item's screen.
  Future<void> _save({bool another = false}) async {
    if (_busy || _loadingValues || _classId == null) {
      if (_classId == null) {
        showError(context, const InputError('Choose a class.'));
      }
      return;
    }
    if (!_form.currentState!.validate()) return;
    if (_withStock && _locationId == null) {
      showError(
        context,
        const InputError(
          'Choose a location for its stock, or turn off Add stock.',
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final item = widget.item;
      if (item == null) {
        await _create(another: another);
      } else {
        await _update(item);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Creates the item, with its first stock row when Add stock is on: both
  /// in one request, so both are made, or neither. Then comes the item's
  /// screen, or with [another], the form for the next item.
  Future<void> _create({required bool another}) async {
    final classId = _classId!;
    final location = _withStock ? _locationId : null;
    final item = await _client.createItem(
      classId: classId,
      name: _name.text.trim(),
      values: newValues(_inputs),
      stock: location == null
          ? null
          : (
              locationId: location,
              amount: _counted ? AmountField.parse(_amount, _rule.unit) : null,
              values: newValues(_stockInputs),
            ),
    );
    if (!mounted) return;
    final recent = context.read<Session>().recent
      ..itemAdded(classId)
      ..addStock = _addStock;
    if (location != null) recent.stockAdded(location);
    showMessage(
      context,
      location == null
          ? 'Created ${item.name}.'
          : 'Created ${item.name}, at ${widget.locations!.pathOf(location)}.',
    );
    context.pushReplacement(another ? '/items/new' : '/items/${item.code}');
  }

  Future<void> _update(ItemDetail item) async {
    final name = _name.text.trim();
    final changes = valueChanges(_inputs);
    final dropped = _dropped;
    if (dropped.isNotEmpty) {
      changes['values'] = {
        for (final n in dropped) n: null,
        ...?changes['values'] as Map<String, Object?>?,
      };
    }
    changes.addAll({
      if (name != item.name) 'name': name,
      if (_classId != item.cls.id) 'class': _classId,
    });
    if (changes.isNotEmpty) await _client.patchItem(item.id, changes);
    if (!mounted) return;
    showMessage(context, changes.isEmpty ? 'No changes.' : 'Saved.');
    context.pop(changes.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final dropped = _dropped;
    final last = _lastField;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit ${widget.item!.name}' : 'New item'),
        actions: [
          if (!_editing)
            AnotherButton(
              label: 'Create and add another',
              onPressed: _busy ? null : _saveAnother,
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_editing ? 'Save' : 'Create'),
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
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Class',
                    border: OutlineInputBorder(),
                  ),
                  child: PickerKeys(
                    open: _chooseClass,
                    child: InkWell(
                      onTap: _chooseClass,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _classId == null
                                  ? 'Choose a class'
                                  : widget.classes.pathOf(_classId),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
                if (dropped.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'In this class it has no ${dropped.join(', ')}: '
                      'saving removes ${dropped.length == 1 ? 'that value' : 'those values'}.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  focusNode: _nameFocus,
                  autofocus: !_editing && _classId != null,
                  textInputAction: identical(last, _name)
                      ? TextInputAction.done
                      : TextInputAction.next,
                  onFieldSubmitted: (_) {
                    if (identical(_lastField, _name)) _save();
                  },
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                if (_valuesError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    errorText(_valuesError!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _loadValues,
                    child: const Text('Try again'),
                  ),
                ],
                if (_loadingValues)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                if (_inputs.isNotEmpty) ...[
                  const SectionTitle('Values'),
                  if (_editing)
                    const EmptyNote(
                      "Clear a value to remove it. Files are uploaded on the item's screen.",
                    ),
                  for (final i in _inputs)
                    Padding(
                      key: ValueKey(i.attribute.name),
                      padding: const EdgeInsets.only(top: 12),
                      child: ValueField(
                        i,
                        onSubmitted: identical(i, last) ? _save : null,
                      ),
                    ),
                ],
                if (!_editing) ..._stockSection(last),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A new item's first stock row: Add stock, then where, how many, and its
  /// stock values; greyed out and left out of Tab's order while Add stock is
  /// off.
  List<Widget> _stockSection(Object last) {
    final on = _addStock;
    final locations = widget.locations!;
    return [
      const SectionTitle('Stock'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Add stock'),
        // How it is counted is its class's.
        subtitle: Text(
          'Its first stock row, saved with it. '
          '${_class == null ? '' : 'Its class: ${_rule.text.toLowerCase()}.'}',
        ),
        value: on,
        onChanged: (v) => setState(() => _addStock = v),
      ),
      const SizedBox(height: 8),
      InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Location',
          border: OutlineInputBorder(),
        ).copyWith(enabled: on),
        child: PickerKeys(
          open: on ? _chooseLocation : null,
          child: InkWell(
            onTap: on ? _chooseLocation : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _locationId == null
                        ? 'Choose a location'
                        : locations.pathOf(_locationId),
                    style: on
                        ? null
                        : TextStyle(color: Theme.of(context).disabledColor),
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
      ),
      // As the class counts its stock: no amount when it doesn't.
      if (_counted) ...[
        const SizedBox(height: 16),
        AmountField(
          controller: _amount,
          unit: _rule.unit,
          focusNode: _amountFocus,
          enabled: on,
          required: _rule.counting == Counting.required,
          onSubmitted: identical(last, _amount) ? _save : null,
        ),
      ],
      for (final i in _stockInputs)
        Padding(
          key: ValueKey(('stock', i.attribute.name)),
          padding: const EdgeInsets.only(top: 12),
          child: ValueField(
            i,
            enabled: on,
            onSubmitted: identical(i, last) ? _save : null,
          ),
        ),
    ];
  }

  void _saveAnother() => _save(another: true);
}
