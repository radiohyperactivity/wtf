import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/value_fields.dart';

/// Adds an item (in [classId], if given), or edits the item with [code].
/// Like `wtf item add` and `wtf item edit`: class, name, unit group, then
/// the class's attributes, required ones first.
class ItemFormScreen extends StatelessWidget {
  const ItemFormScreen({super.key, this.code, this.classId});

  final String? code;
  final String? classId;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final code = this.code;
    return Loader<(ItemDetail?, Tree)>(
      title: code == null ? 'New item' : 'Edit item',
      load: () async {
        final classes = await client.tree(TreeKind.classes);
        if (code == null) return (null, classes);
        final target = await client.code(code);
        if (target is! CodeItem) {
          throw InputError('There is no item with the code $code.');
        }
        return (target.item, classes);
      },
      builder: (context, data, _) =>
          _ItemForm(item: data.$1, classes: data.$2, classId: classId),
    );
  }
}

class _ItemForm extends StatefulWidget {
  const _ItemForm({required this.item, required this.classes, this.classId});

  final ItemDetail? item;
  final Tree classes;
  final String? classId;

  @override
  State<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<_ItemForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late String? _classId = widget.item?.cls.id ?? _usable(widget.classId);
  late UnitGroup? _unitGroup = widget.item?.unitGroup;
  List<ValueInput> _inputs = [];
  bool _loadingValues = false;
  Object? _valuesError;
  bool _busy = false;

  ApiClient get _client => context.read<Session>().client;
  bool get _editing => widget.item != null;

  /// A class items can be in: not a container.
  String? _usable(String? id) =>
      id != null && widget.classes[id]?.container == false ? id : null;

  @override
  void initState() {
    super.initState();
    if (_classId != null) _loadValues();
  }

  @override
  void dispose() {
    _name.dispose();
    for (final i in _inputs) {
      i.dispose();
    }
    super.dispose();
  }

  /// The attribute inputs of the chosen class. Text typed for an attribute
  /// the new class has too is kept.
  Future<void> _loadValues() async {
    final classId = _classId;
    if (classId == null) return;
    setState(() {
      _loadingValues = true;
      _valuesError = null;
    });
    try {
      final typed = {
        for (final i in _inputs) i.attribute.id: i.controller.text,
      };
      final cls = await _client.cls(classId);
      final current = widget.item == null
          ? <String, String>{}
          : ownValues(widget.item!.values);
      final inputs = await loadValueInputs(
        _client,
        cls.attributes,
        perUnit: false,
        current: current,
      );
      for (final i in inputs) {
        final text = typed[i.attribute.id];
        if (text != null) i.controller.text = text;
      }
      if (!mounted || classId != _classId) return;
      final old = _inputs;
      setState(() => _inputs = inputs);
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

  Future<void> _chooseClass() async {
    final id = await pickNode(
      context,
      TreeKind.classes,
      title: 'Class',
      forUse: true,
    );
    if (id == null || id == _classId) return;
    setState(() => _classId = id);
    _loadValues();
  }

  Future<void> _chooseUnitGroup() async {
    final current = widget.item?.unitGroup;
    final g = await pickUnitGroup(
      context,
      // A new item may be counted in pieces; an existing one can only change
      // to another group of the same quantity, as in the CLI.
      noneLabel: _editing ? null : 'None: counted in pieces',
      quantityId: _editing ? current?.quantity.id : null,
    );
    if (g == null) return;
    setState(() => _unitGroup = g.id.isEmpty ? null : g);
  }

  Future<void> _save() async {
    if (_busy || _loadingValues || _classId == null) {
      if (_classId == null) {
        showError(context, const InputError('Choose a class.'));
      }
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final item = widget.item;
      if (item == null) {
        await _create();
      } else {
        await _update(item);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final values = <String, Object?>{
      for (final i in _inputs)
        if (i.text.isNotEmpty) i.attribute.id: i.parse(),
    };
    final item = await _client.createItem(
      classId: _classId!,
      name: _name.text.trim(),
      unitGroupId: _unitGroup?.id,
      values: values,
    );
    if (!mounted) return;
    // As in the CLI: asked once, after the item was created.
    final addStock = await confirm(
      context,
      title: 'Add stock for ${item.name}?',
      message: 'Say where it is, and how many.',
      action: 'Add stock',
      destructive: false,
    );
    if (!mounted) return;
    // With stock, the stock form comes first and then shows the item.
    context.pushReplacement(
      addStock
          ? '/stock/new?item=${item.id}&then=${Uri.encodeComponent('/items/${item.code}')}'
          : '/items/${item.code}',
    );
  }

  Future<void> _update(ItemDetail item) async {
    final name = _name.text.trim();
    final changes = <String, Object?>{
      if (name != item.name) 'name': name,
      if (_classId != item.cls.id) 'class': _classId,
      if (_unitGroup != null && _unitGroup!.id != item.unitGroup?.id)
        'unit_group': _unitGroup!.id,
    };
    final saved = <String>[];
    if (changes.isNotEmpty) {
      await _client.patchItem(item.id, changes);
      saved.addAll(
        changes.keys.map((k) => k == 'unit_group' ? 'unit group' : k),
      );
    }
    final all = await saveValues(
      _inputs,
      set: (a, v) => _client.setItemValue(item.id, a, v),
      remove: (a) => _client.deleteItemValue(item.id, a),
      savedBefore: saved,
    );
    if (!mounted) return;
    showMessage(
      context,
      all.isEmpty ? 'No changes.' : 'Saved: ${all.join(', ')}.',
    );
    context.pop(all.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit ${widget.item!.name}' : 'New item'),
        actions: [
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
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: !_editing && _classId != null,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              if (!_editing || widget.item!.unitGroup != null) ...[
                const SizedBox(height: 16),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Stock is measured in',
                    border: OutlineInputBorder(),
                  ),
                  child: InkWell(
                    onTap: _chooseUnitGroup,
                    child: Row(
                      children: [
                        Expanded(child: Text(_unitGroup?.name ?? 'pieces')),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ],
              if (_valuesError != null) ...[
                const SizedBox(height: 16),
                Text(
                  errorText(_valuesError!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                    'Clear a value to remove it; the class default then applies again.',
                  ),
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
