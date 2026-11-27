import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../api/models.dart';
import '../camera.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';
import '../widgets/form_keys.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';
import '../widgets/value_fields.dart';

/// Adds a stock row (of [itemId] and at [locationId], when given), or edits
/// the row with [code]. Like `wtf stock add` and `wtf stock edit`: item,
/// location and amount (empty: uncounted), then the values of the class's
/// stock attributes. Its photo and files are chosen on it too, and uploaded
/// once it is saved (decision 115).
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
  late final _description = TextEditingController(
    text: widget.stock?.description ?? '',
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

  // The row's photo, and the files of its class's stock attachment
  // attributes, by name.
  late final _photo = FormFile.photo(current: widget.stock?.photo);
  Map<String, FormFile> _files = {};
  ClassDetail? _class;
  bool _loading = false;
  Object? _loadError;
  bool _busy = false;

  ApiClient get _client => context.read<Session>().client;
  bool get _editing => widget.stock != null;

  /// Whether the chosen location takes stock photos (decision 116).
  bool get _photosHere =>
      _locationId != null &&
      (widget.locations[_locationId]?.stockPhotos ?? false);

  /// A location stock can be at: not a container.
  String? _usable(String? id) =>
      id != null && widget.locations[id]?.container == false ? id : null;

  /// Stops this form taking the camera's photos.
  late final VoidCallback _untake;

  @override
  void initState() {
    super.initState();
    if (_item != null) _loadItem();
    // A photo the phone takes for this form is the stock row's, where its
    // location takes one (decisions 116 and 117).
    _untake = context.read<Camera>().takePhotosForForm((photo) {
      if (!_photosHere) {
        showError(
          context,
          InputError(
            _locationId == null
                ? 'Choose a location first: the photo is for its stock row.'
                : 'Stock at ${widget.locations.pathOf(_locationId)} has no photos of its own.',
          ),
        );
        return;
      }
      setState(() {
        _photo
          ..picked = photo
          ..removing = false;
      });
    });
  }

  @override
  void dispose() {
    _untake();
    _amount.dispose();
    _description.dispose();
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
      final files = {
        for (final a in cls.scoped(stock: true))
          if (a.isFile)
            a.name: () {
              final hash = stock?.values[a.name];
              final current = hash is String
                  ? FileRef(
                      owner: '/stock/${stock!.id}',
                      attribute: a.name,
                      hash: hash,
                    )
                  : null;
              return _files[a.name]?.again(a, current: current) ??
                  FormFile.attribute(a, current: current);
            }(),
      };
      setState(() {
        _class = cls;
        _inputs = inputs;
        _files = files;
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
    // A photo only where the location takes one; the one there may still
    // be removed.
    if (!_photosHere) _photo.picked = null;
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
          description: DescriptionField.valueOf(_description),
          values: newValues(_inputs),
        );
        final failed = await uploadFormFiles(_client, '/stock/${created.id}', [
          _photo,
          ..._files.values,
        ]);
        if (mounted) {
          context.read<Session>().recent.stockAdded(location);
          final added =
              'Added ${item.name} at ${widget.locations.pathOf(location)}';
          if (failed.isEmpty) {
            showMessage(context, '$added.');
          } else {
            showError(context, _notUploaded(added, failed));
          }
          if (another && failed.isEmpty) {
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
      DescriptionField.addChange(changes, _description, stock.description);
      final files = [_photo, ..._files.values];
      addFileRemovals(changes, files);
      if (changes.isNotEmpty) await _client.patchStock(stock.id, changes);
      final failed = await uploadFormFiles(
        _client,
        '/stock/${stock.id}',
        files,
      );
      if (mounted) {
        final changed = changes.isNotEmpty || files.any((f) => f.changed);
        if (failed.isEmpty) {
          showMessage(context, changed ? 'Saved.' : 'No changes.');
        } else {
          showError(context, _notUploaded('Saved', failed));
        }
        context.pop(changed);
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
                const SizedBox(height: 16),
                DescriptionField(controller: _description),
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
                if (_photosHere || _photo.current != null) ...[
                  const SizedBox(height: 8),
                  FormFileTile(_photo, canAdd: _photosHere),
                ],
                if (_inputs.isNotEmpty || _files.isNotEmpty) ...[
                  // In the class's order: an input for a value, a line for
                  // a file.
                  for (final a
                      in _class?.scoped(stock: true) ?? const <Attribute>[])
                    if (_files[a.name] case final f?)
                      FormFileTile(f, key: ValueKey(('file', a.name)))
                    else if (_inputs
                            .where((i) => i.attribute.name == a.name)
                            .firstOrNull
                        case final i?)
                      Padding(
                        key: ValueKey(a.name),
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

  /// Says what was saved, and which files weren't uploaded and why; they
  /// can be uploaded again on the stock row's screen.
  InputError _notUploaded(String done, List<String> failed) => InputError(
    "$done, but ${failed.length == 1 ? 'this file was' : 'these files were'} "
    "not uploaded: ${failed.join('; ')}. Upload ${failed.length == 1 ? 'it' : 'them'} on its screen.",
  );
}
