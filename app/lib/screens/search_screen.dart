import 'dart:async';

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

/// The start screen, like `wtf find`: items whose name, class, text or
/// choice values contain every word, each with where its stock is. A label
/// code finds its object too, like `wtf code`.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _pageSize =
      20; // each item takes a request of its own, as in the CLI

  final _query = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  int _generation = 0;

  String? _classId;
  final List<ItemListed> _rows = [];
  int _total = 0;
  bool _loading = false;
  Object? _error;
  CodeTarget? _code;
  final Map<String, Future<ItemDetail>> _details = {};

  // For the paths of classes and locations; refreshed with every search, and
  // as soon as this app changes one.
  Tree? _classes;
  Tree? _locations;
  StreamSubscription<TreeKind>? _treeChanges;

  ApiClient get _client => context.read<Session>().client;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _more();
    });
    _treeChanges = _client.treeChanges.listen((kind) async {
      final Tree tree;
      try {
        tree = await _client.tree(kind);
      } catch (_) {
        return; // fetched again with the next search
      }
      if (!mounted) return;
      setState(() {
        if (kind == TreeKind.classes) {
          _classes = tree;
        } else {
          _locations = tree;
        }
        _details.clear();
      });
    });
  }

  @override
  void dispose() {
    _treeChanges?.cancel();
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _hasSearch => _query.text.trim().isNotEmpty || _classId != null;

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  /// Starts a new search.
  Future<void> _search() async {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _rows.clear();
      _total = 0;
      _error = null;
      _code = null;
      _details.clear();
    });
    if (!_hasSearch) return;
    final text = _query.text.trim();
    // A single word that could be a label code is looked up as one too.
    if (!text.contains(' ') && normalizeCode(text) != null) {
      _client.code(text).then((target) {
        if (mounted && generation == _generation) {
          setState(() => _code = target);
        }
      }, onError: (Object _) {});
    }
    await _load(generation);
  }

  Future<void> _more() async {
    if (_loading || _rows.length >= _total || _error != null) return;
    await _load(_generation);
  }

  Future<void> _load(int generation) async {
    setState(() => _loading = true);
    try {
      if (_rows.isEmpty) {
        final trees = await Future.wait([
          _client.tree(TreeKind.classes),
          _client.tree(TreeKind.locations),
        ]);
        _classes = trees[0];
        _locations = trees[1];
      }
      final page = await _client.items(
        search: _query.text,
        classId: _classId,
        limit: _pageSize,
        offset: _rows.length,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _rows.addAll(page.rows);
        _total = page.total;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      noteError(context, e);
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _chooseClass() async {
    final id = await pickNode(
      context,
      TreeKind.classes,
      title: 'Only items of this class',
    );
    if (id == null) return;
    _classes = await _client.tree(TreeKind.classes);
    setState(() => _classId = id);
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      floatingActionButton: session.canWriteData
          ? FloatingActionButton.extended(
              onPressed: () => context.push(
                _classId == null ? '/items/new' : '/items/new?class=$_classId',
              ),
              icon: const Icon(Icons.add),
              label: const Text('New item'),
            )
          : null,
      body: Readable(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Name, class, value or label code',
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                          onPressed: () {
                            _query.clear();
                            _search();
                          },
                        ),
                ),
                onChanged: (_) => _changed(),
                onSubmitted: (_) => _search(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  InputChip(
                    avatar: const Icon(Icons.category_outlined, size: 18),
                    label: Text(
                      _classId == null
                          ? 'Any class'
                          : (_classes?.pathOf(_classId) ?? '…'),
                    ),
                    onPressed: _chooseClass,
                    onDeleted: _classId == null
                        ? null
                        : () {
                            setState(() => _classId = null);
                            _search();
                          },
                  ),
                  const Spacer(),
                  if (_hasSearch && !_loading && _error == null)
                    Text(
                      '$_total found',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            Expanded(child: _results()),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    if (!_hasSearch) {
      return const EmptyNote(
        'Search items by name, class, and text or choice values: every word must occur somewhere, '
        'so "resistor 0805" finds 0805 resistors. A label code finds its item, stock row or location.',
      );
    }
    final code = _code;
    final codeTile = code == null ? null : _CodeTile(code);
    if (_error != null && _rows.isEmpty) {
      return ListView(children: [?codeTile, EmptyNote(errorText(_error!))]);
    }
    if (_rows.isEmpty && !_loading) {
      return ListView(children: [?codeTile, const EmptyNote('Nothing found.')]);
    }
    final extra = codeTile == null ? 0 : 1;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 88),
      itemCount:
          extra + _rows.length + (_rows.length < _total || _loading ? 1 : 0),
      itemBuilder: (context, i) {
        if (codeTile != null && i == 0) return codeTile;
        i -= extra;
        if (i >= _rows.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final item = _rows[i];
        return _FoundItem(
          item: item,
          detail: _details[item.id] ??= _client.item(item.id),
          classes: _classes!,
          locations: _locations!,
        );
      },
    );
  }
}

/// A label code's object, at the top of the results.
class _CodeTile extends StatelessWidget {
  const _CodeTile(this.target);

  final CodeTarget target;

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle, path) = switch (target) {
      CodeLocation(:final location) => (
        Icons.place_outlined,
        location.pathText,
        'Location ${location.code}',
        '/locations/${location.code}',
      ),
      CodeItem(:final item) => (
        Icons.inventory_2_outlined,
        item.name,
        'Item ${item.code}',
        '/items/${item.code}',
      ),
      CodeStock(:final stock) => (
        Icons.layers_outlined,
        '${stock.item.name}, ${stock.quantityText}',
        'Stock row ${stock.code}',
        '/stock/${stock.code}',
      ),
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text('Label code: $subtitle'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(path),
      ),
    );
  }
}

/// A found item: name, code, class, total stock, and each stock row with
/// its location.
class _FoundItem extends StatelessWidget {
  const _FoundItem({
    required this.item,
    required this.detail,
    required this.classes,
    required this.locations,
  });

  final ItemListed item;
  final Future<ItemDetail> detail;
  final Tree classes;
  final Tree locations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return InkWell(
      onTap: () => context.push('/items/${item.code}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.photo != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AttachmentImage(item.photo!, size: 48),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (item.incomplete)
                        Tooltip(
                          message: 'A required value is missing',
                          child: Icon(
                            Icons.warning_amber,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      Text('  ${item.stockText}'),
                    ],
                  ),
                  Text(
                    '${item.code}  ·  ${classes.pathOf(item.classId)}',
                    style: muted,
                  ),
                  FutureBuilder(
                    future: detail,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Text(errorText(snap.error!), style: muted);
                      }
                      if (!snap.hasData) return const SizedBox(height: 18);
                      final d = snap.data!;
                      if (d.stock.isEmpty) {
                        return Text('(no stock)', style: muted);
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final s in d.stock)
                            InkWell(
                              onTap: () => context.push('/stock/${s.code}'),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.place_outlined,
                                      size: 16,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(locations.pathOf(s.location)),
                                    ),
                                    Text(s.quantityText, style: muted),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
