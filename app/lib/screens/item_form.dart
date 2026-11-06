import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';

/// Adds an item (in [classId], if given), or edits the item with [code].
/// Like `wtf item add` and `wtf item edit`: class, name, what its stock is
/// counted in, then the class's attributes. Saving an item is one request,
/// its fields and values together.
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
  late final _unit = TextEditingController(text: widget.item?.unit ?? '');
  late String? _classId = widget.item?.cls.id ?? _usable(widget.classId);
  ClassDetail? _class;
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
    _unit.dispose();
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
        for (final i in _inputs) i.attribute.name: i.controller.text,
      };
      final cls = await _client.cls(classId);
      final item = widget.item;
      final inputs = valueInputs(
        cls,
        stock: false,
        values: item?.values ?? const {},
        defaulted: item?.defaulted ?? const {},
      );
      for (final i in inputs) {
        final text = typed[i.attribute.name];
        if (text != null) i.controller.text = text;
      }
      if (!mounted || classId != _classId) return;
      final old = _inputs;
      setState(() {
        _class = cls;
        _inputs = inputs;
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

  String? get _unitText => _unit.text.trim().isEmpty ? null : _unit.text.trim();

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
    final item = await _client.createItem(
      classId: _classId!,
      name: _name.text.trim(),
      unit: _unitText,
      values: newValues(_inputs),
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
      if (_unitText != item.unit) 'unit': _unitText,
    });
    if (changes.isNotEmpty) await _client.patchItem(item.id, changes);
    if (!mounted) return;
    showMessage(context, changes.isEmpty ? 'No changes.' : 'Saved.');
    context.pop(changes.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final dropped = _dropped;
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
                autofocus: !_editing && _classId != null,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _unit,
                decoration: const InputDecoration(
                  labelText: 'Unit of its stock',
                  hintText: 'm, kg, l …',
                  helperText:
                      'What its stock is counted in, a label; empty: pieces, '
                      'counted one by one',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
              ),
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
                    "Clear a value to remove it. Files are uploaded on the item's screen.",
                  ),
                for (final i in _inputs)
                  Padding(
                    key: ValueKey(i.attribute.name),
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
