import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import '../widgets/attachments.dart';
import '../widgets/common.dart';
import '../widgets/link.dart';
import '../widgets/pickers.dart';
import '../widgets/value_fields.dart';

/// The start screen, like `wtf find`: search words, a class, and with a
/// class, conditions on its attributes. Search opens the results on top, so
/// Back comes here with everything still filled in.
class ItemSearchScreen extends StatefulWidget {
  const ItemSearchScreen({super.key});

  @override
  State<ItemSearchScreen> createState() => _ItemSearchScreenState();
}

class _ItemSearchScreenState extends State<ItemSearchScreen> {
  final _form = GlobalKey<FormState>();
  final _query = TextEditingController();
  String? _classId;
  Tree? _classes;
  List<_Condition> _conditions = [];
  bool _loadingConditions = false;
  Object? _conditionsError;
  int _generation = 0;
  StreamSubscription<TreeKind>? _treeChanges;

  ApiClient get _client => context.read<Session>().client;

  @override
  void initState() {
    super.initState();
    _treeChanges = _client.treeChanges.listen((kind) async {
      if (kind != TreeKind.classes) return;
      final tree = await _client.tree(kind);
      if (mounted) setState(() => _classes = tree);
    });
  }

  @override
  void dispose() {
    _treeChanges?.cancel();
    _query.dispose();
    for (final c in _conditions) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseClass() async {
    final id = await pickNode(
      context,
      TreeKind.classes,
      title: 'Only items of this class',
    );
    if (id == null || id == _classId) return;
    _classes = await _client.tree(TreeKind.classes);
    setState(() => _classId = id);
    _loadConditions();
  }

  void _clearClass() {
    setState(() => _classId = null);
    _loadConditions();
  }

  /// The condition fields for the chosen class's attributes, its own and
  /// inherited ones, as `wtf class get` lists them.
  Future<void> _loadConditions() async {
    final generation = ++_generation;
    final old = _conditions;
    setState(() {
      _conditions = [];
      _conditionsError = null;
      _loadingConditions = _classId != null;
    });
    // The old fields are still drawn once more.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
    final classId = _classId;
    if (classId == null) return;
    try {
      final cls = await _client.cls(classId);
      final conditions = await Future.wait(
        cls.attributes.map((ca) async {
          final a = ca.attribute.datatype == 'choice'
              ? await _client.attribute(ca.attribute.id)
              : ca.attribute;
          final unit = a.unit;
          return _Condition(
            a,
            perUnit: ca.perUnit,
            units: unit == null ? null : await _client.unitChoice(unit),
          );
        }),
      );
      if (!mounted || generation != _generation) {
        for (final c in conditions) {
          c.dispose();
        }
        return;
      }
      setState(() => _conditions = conditions);
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _conditionsError = e);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingConditions = false);
      }
    }
  }

  void _clear() {
    _query.clear();
    for (final c in _conditions) {
      c.clear();
    }
    setState(() {});
  }

  void _search() {
    if (!_form.currentState!.validate()) return;
    final filters = [for (final c in _conditions) ?c.filter()];
    context.push(
      Uri(
        path: '/found',
        queryParameters: {
          if (_query.text.trim().isNotEmpty) 'search': _query.text.trim(),
          'class': ?_classId,
          if (filters.isNotEmpty) 'where': ApiClient.encodeWhere(filters),
        },
      ).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final query = TextField(
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
                onPressed: () => setState(_query.clear),
              ),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _search(),
    );
    final classField = InkWell(
      onTap: _chooseClass,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Class',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.category_outlined),
          suffixIcon: _classId == null
              ? const Icon(Icons.arrow_drop_down)
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Any class',
                  onPressed: _clearClass,
                ),
        ),
        child: Text(
          _classId == null ? 'Any class' : (_classes?.pathOf(_classId) ?? '…'),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    final button = FilledButton.icon(
      onPressed: _search,
      icon: const Icon(Icons.search),
      label: const Text('Search'),
      style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [TextButton(onPressed: _clear, child: const Text('Clear'))],
      ),
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
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
            children: [
              // Wide: search, class and the button in a row. Narrow: the
              // class and the button share a row under the search.
              LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 560
                    ? Row(
                        children: [
                          Expanded(flex: 3, child: query),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: classField),
                          const SizedBox(width: 8),
                          button,
                        ],
                      )
                    : Column(
                        children: [
                          query,
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: classField),
                              const SizedBox(width: 8),
                              button,
                            ],
                          ),
                        ],
                      ),
              ),
              if (_classId == null)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Search items by name, class, and text or choice values: every word must occur somewhere, '
                    'so "resistor 0805" finds 0805 resistors. A label code finds its item, stock row or location. '
                    'Choose a class to search by its attributes too. Search with nothing filled in lists every item.',
                  ),
                ),
              if (_loadingConditions)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (_conditionsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    errorText(_conditionsError!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_conditions.isNotEmpty) ...[
                const SectionTitle('Attributes'),
                Text(
                  'Numbers and dates: 32k, > 32kohm, >= 2026-01-01, or a range 10k..47k. '
                  'Per-unit attributes match when any stock row does.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final c in _conditions)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ConditionField(c, onChanged: () => setState(() {})),
                  ),
              ] else if (_classId != null &&
                  !_loadingConditions &&
                  _conditionsError == null)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('This class has no attributes.'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A condition on one attribute in the search form: text for numbers, dates
/// and text, options for choices, any/yes/no for yes/no.
class _Condition {
  _Condition(this.attribute, {required this.perUnit, this.units})
    : controller = MeasureController(plainIn: units?.unit);

  final Attribute attribute;
  final bool perUnit;
  final UnitChoice? units;
  final MeasureController controller;
  final Set<String> options = {};
  bool? yes;

  void clear() {
    controller.clear();
    controller.plainIn = units?.unit;
    options.clear();
    yes = null;
  }

  /// The filter for GET /items?where=, or null when nothing is asked for.
  Map<String, Object>? filter() {
    final a = attribute;
    switch (a.datatype) {
      case 'choice':
        return options.isEmpty
            ? null
            : {'attribute': a.id, 'op': 'in', 'value': options.toList()};
      case 'boolean':
        return yes == null
            ? null
            : {'attribute': a.id, 'op': '=', 'value': yes!};
      case 'integer' || 'float' || 'date':
        return parseCondition(a, controller.text, units, controller.plainIn);
      default:
        final text = controller.text.trim();
        return text.isEmpty
            ? null
            : {'attribute': a.id, 'op': 'contains', 'value': text};
    }
  }

  String? validate() {
    try {
      filter();
      return null;
    } on InputError catch (e) {
      final prefix = '${attribute.name}: ';
      return e.message.startsWith(prefix)
          ? e.message.substring(prefix.length)
          : e.message;
    }
  }

  void dispose() => controller.dispose();
}

class _ConditionField extends StatelessWidget {
  const _ConditionField(this.condition, {required this.onChanged});

  final _Condition condition;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = condition;
    final a = c.attribute;
    final label = c.perUnit ? '${a.name} (per unit)' : a.name;
    switch (a.datatype) {
      case 'choice':
        return InputDecorator(
          decoration: InputDecoration(
            labelText: '$label: any of',
            border: const OutlineInputBorder(),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final o in a.options)
                FilterChip(
                  label: Text(o.name),
                  selected: c.options.contains(o.id),
                  onSelected: (on) {
                    on ? c.options.add(o.id) : c.options.remove(o.id);
                    onChanged();
                  },
                ),
            ],
          ),
        );
      case 'boolean':
        return InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          child: SegmentedButton<bool?>(
            segments: const [
              ButtonSegment(value: null, label: Text('Any')),
              ButtonSegment(value: true, label: Text('Yes')),
              ButtonSegment(value: false, label: Text('No')),
            ],
            selected: {c.yes},
            onSelectionChanged: (s) {
              c.yes = s.first;
              onChanged();
            },
          ),
        );
    }
    final units = c.units;
    final number = a.datatype == 'integer' || a.datatype == 'float';
    return TextFormField(
      controller: c.controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: switch (a.datatype) {
          'date' => '>= 2026-01-01, or -1y..today',
          _ when number =>
            units == null
                ? '>= 10, or 10..20'
                : '>= 10, or 10..20, in ${units.unit.symbol} or with a unit',
          _ => 'contains',
        },
        border: const OutlineInputBorder(),
        suffixIcon: units == null
            ? null
            : UnitMenu(
                units: units,
                controller: c.controller,
                onChanged: onChanged,
              ),
      ),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) => c.validate(),
    );
  }
}

/// Items found by the search form (or a link to them): search words, class
/// and attribute filters as in GET /items. A label code finds its object
/// too, like `wtf code`. Compact rows on narrow screens, a table with the
/// items' attributes on wide ones.
class FoundItemsScreen extends StatefulWidget {
  const FoundItemsScreen({super.key, this.search, this.classId, this.where});

  final String? search;
  final String? classId;

  /// Attribute filters as JSON (GET /items?where=).
  final String? where;

  @override
  State<FoundItemsScreen> createState() => _FoundItemsScreenState();
}

class _FoundItemsScreenState extends State<FoundItemsScreen> {
  static const _pageSize =
      20; // each item takes a request of its own, as in the CLI

  /// Narrower than this, results are compact rows; wider, a table.
  static const _tableWidth = 720.0;

  final _scroll = ScrollController();
  final List<ItemListed> _rows = [];
  int _total = 0;
  bool _loading = false;
  Object? _error;
  CodeTarget? _code;
  final Map<String, Future<ItemDetail>> _details = {};
  final Map<String, ItemDetail> _loaded = {};

  // For the paths of classes and locations, refreshed as soon as this app
  // changes one.
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
        return;
      }
      if (!mounted) return;
      setState(() {
        if (kind == TreeKind.classes) {
          _classes = tree;
        } else {
          _locations = tree;
        }
        _details.clear();
        _loaded.clear();
        for (final r in _rows) {
          _detail(r.id);
        }
      });
    });
    final text = widget.search?.trim() ?? '';
    // A single word that could be a label code is looked up as one too.
    if (text.isNotEmpty && !text.contains(' ') && normalizeCode(text) != null) {
      _client.code(text).then((target) {
        if (mounted) setState(() => _code = target);
      }, onError: (Object _) {});
    }
    _load();
  }

  @override
  void dispose() {
    _treeChanges?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<ItemDetail> _detail(String id) =>
      _details[id] ??= _client.item(id).then((d) {
        if (mounted) setState(() => _loaded[id] = d);
        return d;
      });

  Future<void> _more() async {
    if (_loading || _rows.length >= _total || _error != null) return;
    await _load();
  }

  Future<void> _load() async {
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
        search: widget.search,
        classId: widget.classId,
        where: widget.where,
        limit: _pageSize,
        offset: _rows.length,
      );
      if (!mounted) return;
      setState(() {
        _rows.addAll(page.rows);
        _total = page.total;
      });
      for (final r in page.rows) {
        _detail(r.id).ignore();
      }
    } catch (e) {
      if (!mounted) return;
      noteError(context, e);
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _loading && _rows.isEmpty
              ? 'Found items'
              : _total == 1
              ? '1 item found'
              : '$_total items found',
        ),
      ),
      body: LayoutBuilder(
        builder: (context, c) =>
            c.maxWidth < _tableWidth ? Readable(child: _compact()) : _table(c),
      ),
    );
  }

  /// Something to show instead of rows, or null when there are rows.
  Widget? _instead(Widget? codeTile) {
    if (_error != null && _rows.isEmpty) {
      return ListView(children: [?codeTile, EmptyNote(errorText(_error!))]);
    }
    if (_rows.isEmpty && !_loading) {
      return ListView(children: [?codeTile, const EmptyNote('Nothing found.')]);
    }
    if (_rows.isEmpty) return const Center(child: CircularProgressIndicator());
    return null;
  }

  bool get _hasMore => _rows.length < _total || _loading;

  static const _progress = Padding(
    padding: EdgeInsets.all(16),
    child: Center(child: CircularProgressIndicator()),
  );

  Widget _compact() {
    final code = _code;
    final codeTile = code == null ? null : _CodeTile(code);
    final instead = _instead(codeTile);
    if (instead != null) return instead;
    final extra = codeTile == null ? 0 : 1;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: extra + _rows.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (codeTile != null && i == 0) return codeTile;
        i -= extra;
        if (i >= _rows.length) return _progress;
        final item = _rows[i];
        return _FoundItem(
          item: item,
          detail: _detail(item.id),
          classes: _classes!,
          locations: _locations!,
        );
      },
    );
  }

  /// The attributes the loaded items show, in the order they were first
  /// seen, so columns don't move as more rows load. Only the items' own
  /// values: per-unit ones belong to stock rows, shown on the item.
  List<(String, String)> get _attributeColumns {
    final seen = <String, String>{};
    for (final r in _rows) {
      final d = _loaded[r.id];
      if (d == null) continue;
      for (final v in d.values) {
        seen.putIfAbsent(v.attribute.id, () => v.attribute.name);
      }
    }
    return [for (final e in seen.entries) (e.key, e.value)];
  }

  Widget _table(BoxConstraints c) {
    final code = _code;
    final codeTile = code == null ? null : _CodeTile(code);
    final instead = _instead(codeTile);
    if (instead != null) return instead;
    final theme = Theme.of(context);
    final columns = _attributeColumns;
    const fixed = [
      ('Item', 280.0),
      ('Class', 170.0),
      ('Stock', 90.0),
      ('Where', 200.0),
    ];
    const attributeWidth = 130.0;
    final width = math.max(
      c.maxWidth,
      fixed.fold(0.0, (w, f) => w + f.$2) +
          columns.length * attributeWidth +
          32,
    );
    Widget cell(double w, Widget child) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: child,
      ),
    );
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final header = Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final (name, w) in fixed)
            cell(w, Text(name, style: theme.textTheme.labelLarge)),
          for (final (_, name) in columns)
            cell(
              attributeWidth,
              Text(
                name,
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    // At most three lines, so one long value doesn't make its row tall;
    // the whole of a longer one in a tooltip.
    Widget short(String text, {TextStyle? style}) => Tooltip(
      message: text.length > 40 ? text : '',
      child: Text(
        text,
        style: style,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );

    Widget row(ItemListed item) {
      final d = _loaded[item.id];
      String where = '';
      final values = <String, (String, bool, bool)>{};
      if (d != null) {
        where = d.stock.isEmpty
            ? '(no stock)'
            : {for (final s in d.stock) _locations!.pathOf(s.location)}
                  .join(', ');
        for (final v in d.values) {
          values[v.attribute.id] = (
            v.text,
            v.isDefault,
            v.attribute.datatype == 'url',
          );
        }
      }
      return InkWell(
        onTap: () => context.push('/items/${item.code}'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cell(
                fixed[0].$2,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PhotoOrIcon(item.photo, icon: Icons.inventory_2_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  item.name,
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              if (item.incomplete)
                                Tooltip(
                                  message: 'A required value is missing',
                                  child: Icon(
                                    Icons.warning_amber,
                                    size: 16,
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                          Text(item.code, style: muted),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              cell(fixed[1].$2, short(_classes!.pathOf(item.classId))),
              cell(fixed[2].$2, short(item.stockText)),
              cell(fixed[3].$2, short(where, style: muted)),
              for (final (id, _) in columns)
                cell(attributeWidth, switch (values[id]) {
                  (final text, _, true) => LinkText(text, maxLines: 3),
                  (final text, final isDefault, _) => short(
                    text,
                    style: isDefault
                        ? muted.copyWith(fontStyle: FontStyle.italic)
                        : null,
                  ),
                  null => const SizedBox.shrink(),
                }),
            ],
          ),
        ),
      );
    }

    final extra = codeTile == null ? 0 : 1;
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          height: c.maxHeight,
          child: Column(
            children: [
              header,
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: extra + _rows.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (codeTile != null && i == 0) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(width: 600, child: codeTile),
                      );
                    }
                    i -= extra;
                    if (i >= _rows.length) return _progress;
                    return row(_rows[i]);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label code's object, at the top of the results.
class _CodeTile extends StatelessWidget {
  const _CodeTile(this.target);

  final CodeTarget target;

  @override
  Widget build(BuildContext context) {
    // Deleted things are shown as such; a stock row a move merged into
    // another leads to that row.
    final (icon, title, subtitle, path) = switch (target) {
      CodeLocation(:final location) => (
        Icons.place_outlined,
        location.pathText,
        'Location ${location.code}${location.deleted ? ', deleted' : ''}',
        '/locations/${location.code}',
      ),
      CodeItem(:final item) => (
        Icons.inventory_2_outlined,
        item.name,
        'Item ${item.code}${item.deleted ? ', deleted' : ''}',
        '/items/${item.code}',
      ),
      CodeStock(:final stock) when stock.mergedInto != null => (
        Icons.layers_outlined,
        stock.item.name,
        'Stock row ${stock.code}, merged into ${stock.mergedInto}',
        '/stock/${stock.mergedInto}',
      ),
      CodeStock(:final stock) => (
        Icons.layers_outlined,
        '${stock.item.name}, ${stock.quantityText}',
        'Stock row ${stock.code}${stock.deleted ? ', deleted' : ''}',
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
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: PhotoOrIcon(item.photo, icon: Icons.inventory_2_outlined),
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
