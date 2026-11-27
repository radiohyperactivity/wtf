import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/input.dart';
import '../camera.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/files.dart';
import '../widgets/form_keys.dart';
import '../widgets/pickers.dart';
import '../widgets/select_keys.dart';

/// What the form starts from: a new node (under [parentId]) or an existing
/// one, by label code (locations) or id (classes).
class NodeFormArgs {
  const NodeFormArgs.add(this.kind, {this.parentId}) : ref = null;
  const NodeFormArgs.edit(this.kind, String this.ref) : parentId = null;

  final TreeKind kind;
  final String? parentId;
  final String? ref;
}

class _Node {
  const _Node({
    required this.id,
    required this.name,
    this.description,
    this.parent,
    this.container = false,
    this.code,
    this.photo,
    this.stockPhotos = false,
  });

  final String id;
  final String name;
  final String? description;
  final String? parent;
  final bool container;
  final String? code;

  /// Locations only.
  final FileRef? photo;
  final bool stockPhotos;
}

/// Adds or edits a location or class, like `wtf location add|edit`: name,
/// parent and container; a new location may get a compartment grid. A
/// location also has its photo, uploaded once it is saved (decision 115),
/// and whether its stock rows may have photos (decision 116).
class NodeFormScreen extends StatelessWidget {
  const NodeFormScreen(this.args, {super.key});

  final NodeFormArgs args;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final locations = args.kind == TreeKind.locations;
    final noun = locations ? 'location' : 'class';
    return Loader<(_Node?, Tree)>(
      title: args.ref == null ? 'New $noun' : 'Edit $noun',
      load: () async {
        final tree = await client.tree(args.kind);
        final ref = args.ref;
        if (ref == null) return (null, tree);
        if (locations) {
          final target = await client.code(ref);
          if (target is! CodeLocation) {
            throw InputError('There is no location with the code $ref.');
          }
          final l = target.location;
          return (
            _Node(
              id: l.id,
              name: l.name,
              description: l.description,
              parent: l.parent,
              container: l.container,
              code: l.code,
              photo: l.photo,
              stockPhotos: l.stockPhotos,
            ),
            tree,
          );
        }
        final c = await client.cls(ref);
        return (
          _Node(
            id: c.id,
            name: c.name,
            description: c.description,
            parent: c.parent,
            container: c.container,
          ),
          tree,
        );
      },
      builder: (context, data, _) =>
          _NodeForm(args: args, node: data.$1, tree: data.$2),
    );
  }
}

class _NodeForm extends StatefulWidget {
  const _NodeForm({required this.args, required this.node, required this.tree});

  final NodeFormArgs args;
  final _Node? node;
  final Tree tree;

  @override
  State<_NodeForm> createState() => _NodeFormState();
}

class _NodeFormState extends State<_NodeForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.node?.name ?? '');
  late final _description = TextEditingController(
    text: widget.node?.description ?? '',
  );
  final _columns = TextEditingController(text: '8');
  final _rows = TextEditingController(text: '5');
  // A new one's parent: what the form was opened for ("Add" on a location
  // or class), else the parent of the last one made in this session, else
  // the top level (decision 122).
  late String? _parent = widget.node != null
      ? widget.node!.parent
      : widget.args.parentId ?? _recentParent();
  late bool _container = widget.node?.container ?? false;
  bool _grid = false;
  bool _busy = false;

  // A location's photo, and whether its stock rows may have photos: a new
  // one's as its parent's until changed here.
  late final _photo = FormFile.photo(current: widget.node?.photo);
  late bool? _stockPhotos = widget.node?.stockPhotos;

  bool get _stockPhotosShown =>
      _stockPhotos ??
      (_parent == null ? false : widget.tree[_parent]?.stockPhotos ?? false);

  bool get _locations => widget.args.kind == TreeKind.locations;

  String? _recentParent() {
    final recent = context.read<Session>().recent;
    bool exists(String id) => widget.tree[id] != null;
    return _locations
        ? recent.locationParent(exists)
        : recent.classParent(exists);
  }

  String get _noun => _locations ? 'location' : 'class';

  /// Stops this form taking the camera's photos; a location's form only.
  VoidCallback? _untake;

  @override
  void initState() {
    super.initState();
    // A photo the phone takes for a location's form is its photo
    // (decision 117).
    if (_locations) {
      _untake = context.read<Camera>().takePhotosForForm(
        (photo) => setState(() {
          _photo
            ..picked = photo
            ..removing = false;
        }),
      );
    }
  }

  @override
  void dispose() {
    _untake?.call();
    _name.dispose();
    _description.dispose();
    _columns.dispose();
    _rows.dispose();
    super.dispose();
  }

  (int, int)? get _gridSize {
    final c = int.tryParse(_columns.text.trim()),
        r = int.tryParse(_rows.text.trim());
    if (c == null ||
        r == null ||
        c < 1 ||
        r < 1 ||
        c > 1 << 20 ||
        r > 1 << 20) {
      return null;
    }
    return (c, r);
  }

  Future<void> _chooseParent([String query = '']) async {
    final node = widget.node;
    final id = await pickNode(
      context,
      widget.args.kind,
      query: query,
      title: 'Choose the parent',
      allowTopLevel: true,
      // A node can't move into itself or below itself.
      exclude: node == null ? const {} : widget.tree.subtree(node.id),
    );
    if (id != null) setState(() => _parent = id == topLevel ? null : id);
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final client = context.read<Session>().client;
    final name = _name.text.trim();
    final node = widget.node;
    setState(() => _busy = true);
    try {
      if (node == null) {
        final grid = _locations && _grid ? _gridSize : null;
        var confirmed = false;
        if (grid != null) {
          // The box, its compartments, and (unlike the CLI) no missing parents.
          final count = grid.$1 * grid.$2 + 1;
          if (count > gridConfirmLimit) {
            confirmed = await confirm(
              context,
              title: 'Create $count locations?',
              message:
                  'The grid creates ${grid.$1 * grid.$2} compartments plus the location itself.',
              action: 'Create',
              destructive: false,
            );
            if (!confirmed) return;
          }
        }
        final String target;
        if (_locations) {
          final l = await client.createLocation(
            name: name,
            parentId: _parent,
            container: _container,
            grid: grid,
            confirm: confirmed,
            stockPhotos: _stockPhotos,
            description: DescriptionField.valueOf(_description),
          );
          final failed = await uploadFormFiles(client, '/locations/${l.id}', [
            _photo,
          ]);
          if (mounted) {
            context.read<Session>().recent.locationMade(l.id, _parent);
            _sayNotUploaded('Created ${l.name}', failed);
          }
          target = '/locations/${l.code}';
        } else {
          final c = await client.createClass(
            name: name,
            parentId: _parent,
            container: _container,
            description: DescriptionField.valueOf(_description),
          );
          if (mounted) context.read<Session>().recent.classMade(c.id, _parent);
          target = '/classes/${c.id}';
        }
        if (mounted) context.pushReplacement(target);
        return;
      }
      final changes = <String, Object?>{
        if (name != node.name) 'name': name,
        if (_parent != node.parent) 'parent': _parent,
        if (_container != node.container) 'container': _container,
        if (_locations && _stockPhotosShown != node.stockPhotos)
          'stock_photos': _stockPhotosShown,
      };
      DescriptionField.addChange(changes, _description, node.description);
      if (_locations) addFileRemovals(changes, [_photo]);
      if (changes.isEmpty && !_photo.changed) {
        if (mounted) context.pop(false);
        return;
      }
      if (_locations) {
        if (changes.isNotEmpty) await client.patchLocation(node.id, changes);
        final failed = await uploadFormFiles(client, '/locations/${node.id}', [
          _photo,
        ]);
        if (mounted) _sayNotUploaded('Saved', failed);
      } else {
        await client.patchClass(node.id, changes);
      }
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Says which files weren't uploaded, and why, when any weren't; they can
  /// be uploaded again on the location's screen.
  void _sayNotUploaded(String done, List<String> failed) {
    if (failed.isEmpty) return;
    showError(
      context,
      InputError(
        "$done, but its photo wasn't uploaded: ${failed.join('; ')}. "
        'Upload it on its screen.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.node != null;
    final grid = _gridSize;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit $_noun' : 'New $_noun'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(editing ? 'Save' : 'Create'),
            ),
          ),
        ],
      ),
      body: Readable(
        maxWidth: 640,
        child: FormKeys(
          save: _save,
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: !editing,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                  validator: (v) {
                    final name = (v ?? '').trim();
                    if (name.isEmpty) return 'Enter a name';
                    if (name.contains('/')) {
                      return 'Names can\'t contain "/": it separates the parts of a path';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                DescriptionField(controller: _description),
                const SizedBox(height: 16),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Parent',
                    border: OutlineInputBorder(),
                  ),
                  child: PickerKeys(
                    open: _chooseParent,
                    child: InkWell(
                      onTap: _chooseParent,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _parent == null
                                  ? '(top level)'
                                  : widget.tree.pathOf(_parent),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_locations) ...[
                  const SizedBox(height: 8),
                  FormFileTile(_photo),
                ],
                const SizedBox(height: 8),
                SwitchTile(
                  title: const Text('Container'),
                  subtitle: Text(
                    _locations
                        ? 'Holds only other locations, no stock (a box of compartments, say).'
                        : 'Holds only other classes, no items.',
                  ),
                  value: _container || _grid,
                  onChanged: _grid
                      ? null
                      : (v) => setState(() => _container = v),
                ),
                if (_locations)
                  SwitchTile(
                    title: const Text('Photos of stock'),
                    subtitle: Text(
                      editing
                          ? 'Stock rows here may have a photo of their own. '
                                'Turned off, those they have stay.'
                          : 'Stock rows here may have a photo of their own. '
                                'At first as its parent; compartments as their box.',
                    ),
                    value: _stockPhotosShown,
                    onChanged: (v) => setState(() => _stockPhotos = v),
                  ),
                if (_locations && !editing) ...[
                  SwitchTile(
                    title: const Text('Compartment grid'),
                    subtitle: const Text(
                      'Also creates a compartment for every cell, named like spreadsheet cells: '
                      'columns A, B, …, rows 1, 2, …',
                    ),
                    value: _grid,
                    onChanged: (v) => setState(() => _grid = v),
                  ),
                  if (_grid) ...[
                    Row(
                      children: [
                        Expanded(child: _number(_columns, 'Columns')),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('×'),
                        ),
                        Expanded(child: _number(_rows, 'Rows')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      grid == null
                          ? 'A grid has at least 1 column and 1 row.'
                          : '${grid.$1 * grid.$2} compartments, A1 … ${columnLabel(grid.$1)}${grid.$2}. '
                                'The location becomes a container, so stock goes into the compartments.',
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A grid's columns or rows; Enter in the rows, the last field, saves.
  Widget _number(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        textInputAction: identical(controller, _rows)
            ? TextInputAction.done
            : TextInputAction.next,
        onFieldSubmitted: (_) {
          if (identical(controller, _rows)) _save();
        },
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => setState(() {}),
        validator: (v) =>
            (int.tryParse(v ?? '') ?? 0) < 1 ? 'At least 1' : null,
      );
}
