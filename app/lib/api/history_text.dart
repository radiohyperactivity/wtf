// History entries in words. The server sends one entry per changed row, with
// ids (see api/history.md); this turns the entries of one action (one
// transaction) into sentences with names, numbers in units and links:
// "Moved 2 from Garage/Shelf 1 to Garage/Shelf 2", "Voltage: 12 V → 18 V".

import 'client.dart';
import 'models.dart';
import 'units.dart';

/// One sentence, and the app path tapping it leads to, if any.
class HistoryLine {
  const HistoryLine(this.text, [this.link]);

  final String text;
  final String? link;
}

/// What one action did: the entries of one transaction, in words.
class HistoryEvent {
  const HistoryEvent({
    required this.happenedAt,
    required this.who,
    required this.whoDeleted,
    required this.entries,
    required this.lines,
  });

  final DateTime? happenedAt;
  final String? who;
  final bool whoDeleted;
  final List<HistoryEntry> entries;
  final List<HistoryLine> lines;
}

/// Whose history it is: the kind of the history route and the object's id.
class HistoryFocus {
  const HistoryFocus(this.kind, [this.id]);

  /// items, stock, locations, classes, attributes or accounts.
  final String kind;

  /// Null: the list itself, i.e. the top level of a tree or all attributes.
  final String? id;
}

/// The label code of a code number, as the server writes it (Crockford
/// Base32): 32768 → 1000.
String codeText(Object? number) {
  if (number is! num) return number?.toString() ?? '';
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var rest = number.toInt();
  var text = '';
  do {
    text = alphabet[rest % 32] + text;
    rest ~/= 32;
  } while (rest > 0);
  return text;
}

class _Named {
  const _Named(this.name, {this.link, this.code = '', this.deleted = false});

  final String name;
  final String? link;
  final String code;
  final bool deleted;
}

class _ItemInfo {
  const _ItemInfo(this.name, this.code, this.unit, this.unitLock);

  final String name;
  final String code;
  final int? unit;
  final bool unitLock;
}

/// The names of what history entries refer to, looked up once: classes and
/// locations from the trees, or fetched when they are deleted; items,
/// attributes, options and stock rows from the entries themselves or the
/// server. Things that were purged since stay unnamed.
class HistoryNames {
  HistoryNames(this.client);

  final ApiClient client;
  Tree? _locations;
  Tree? _classes;
  final _location = <String, _Named>{};
  final _class = <String, _Named>{};
  final _item = <String, _ItemInfo>{};
  final _stock = <String, (String code, String item, String location)>{};
  final _attribute = <String, Attribute>{};
  final _option = <String, String>{};
  final _unit = <int, Unit>{};
  final _attachmentTitle = <String, String>{};
  final _familyUnits = <int, List<Unit>>{};
  final _tried = <String>{};

  /// Looks up what [entries] refer to and isn't known yet.
  Future<void> load(List<HistoryEntry> entries) async {
    _locations ??= await _maybe(client.tree(TreeKind.locations));
    _classes ??= await _maybe(client.tree(TreeKind.classes));
    if (_unit.isEmpty && _tried.add('units')) {
      for (final f in await _maybe(client.unitFamilies()) ?? <UnitFamily>[]) {
        _familyUnits[f.id] = f.units;
        for (final u in f.units) {
          _unit[u.id] = u;
        }
      }
    }

    final locations = <String>{}, classes = <String>{}, items = <String>{};
    final stock = <String>{}, attributes = <String>{}, options = <String>{};
    void both(HistoryEntry e, String column, Set<String> into) {
      for (final v in [e.data[column], e.change(column)?.old]) {
        if (v is String) into.add(v);
      }
    }

    for (final e in entries) {
      final d = e.data;
      switch (e.table) {
        case 'location':
          _location[e.rowId] = _Named(
            '${d['name']}',
            link: '/locations/${codeText(d['code'])}',
            code: codeText(d['code']),
            deleted: d['deleted'] == true,
          );
          both(e, 'parent', locations);
        case 'class':
          _class[e.rowId] = _Named(
            '${d['name']}',
            link: '/classes/${e.rowId}',
            deleted: d['deleted'] == true,
          );
          both(e, 'parent', classes);
        case 'item':
          _item[e.rowId] = _ItemInfo(
            '${d['name']}',
            codeText(d['code']),
            d['unit'] as int?,
            d['unit_lock'] == true,
          );
          both(e, 'class', classes);
        case 'stock':
          _stock[e.rowId] = (
            codeText(d['code']),
            '${d['item']}',
            '${d['location']}',
          );
          both(e, 'item', items);
          both(e, 'location', locations);
          if (d['merged_into'] is String) stock.add(d['merged_into'] as String);
        case 'value' || 'stock_value' || 'class_attribute':
          if (d['item'] is String) items.add(d['item'] as String);
          if (d['stock'] is String) stock.add(d['stock'] as String);
          attributes.add('${d['attribute']}');
          both(e, 'option_value', options);
          both(e, 'option_default', options);
        case 'item_attachment' ||
            'stock_attachment' ||
            'location_attachment' ||
            'class_attachment':
          // Entries come newest first: the latest title wins.
          _attachmentTitle.putIfAbsent('${d['id']}', () => '${d['title']}');
        case 'attribute_option':
          _option[e.rowId] = '${d['name']}';
          attributes.add('${d['attribute']}');
      }
    }

    await Future.wait([
      for (final id in locations.difference({..._location.keys}))
        if (_locations?[id] == null && _tried.add(id))
          _maybe(client.location(id)).then((l) {
            if (l != null) {
              _location[id] = _Named(
                l.pathText,
                link: '/locations/${l.code}',
                code: l.code,
                deleted: l.deleted,
              );
            }
          }),
      for (final id in classes.difference({..._class.keys}))
        if (_classes?[id] == null && _tried.add(id))
          _maybe(client.cls(id)).then((c) {
            if (c != null) {
              _class[id] = _Named(
                c.pathText,
                link: '/classes/$id',
                deleted: c.deleted,
              );
            }
          }),
      for (final id in items.difference({..._item.keys}))
        if (_tried.add(id))
          _maybe(client.item(id)).then((i) {
            if (i != null) {
              _item[id] = _ItemInfo(i.name, i.code, i.unit?.id, i.unitLock);
            }
          }),
      for (final id in stock.difference({..._stock.keys}))
        if (_tried.add(id))
          _maybe(client.stock(id)).then((s) {
            if (s != null) {
              _stock[id] = (s.code, s.item.id, s.location);
              _item.putIfAbsent(
                s.item.id,
                () => _ItemInfo(
                  s.item.name,
                  s.item.code,
                  s.item.unit?.id,
                  s.item.unitLock,
                ),
              );
            }
          }),
      for (final id in attributes.difference({..._attribute.keys}))
        if (_tried.add(id))
          _maybe(client.attribute(id)).then((a) {
            if (a != null) {
              _attribute[id] = a;
              for (final o in a.options) {
                _option[o.id] = o.name;
              }
            }
          }),
    ]);

    // Options of deleted attributes and deleted options.
    await Future.wait([
      for (final id in options.difference({..._option.keys}))
        if (_tried.add(id))
          _maybe(client.option(id)).then((o) {
            if (o != null) _option[id] = '${o['name']}';
          }),
    ]);
  }

  static Future<T?> _maybe<T>(Future<T> f) async {
    try {
      return await f;
    } catch (_) {
      return null; // purged, or not readable with this account's privileges
    }
  }

  // --- Names ---

  _Named _loc(Object? id) {
    final n = _locations?[id as String?];
    if (n != null) {
      return _Named(n.path, link: '/locations/${n.code}', code: n.code ?? '');
    }
    final known = _location[id];
    if (known == null) return const _Named('a location');
    // A deleted location's own entry only knows its name; a fetched one its path.
    return known;
  }

  _Named _cls(Object? id) {
    final n = _classes?[id as String?];
    if (n != null) return _Named(n.path, link: '/classes/${n.id}');
    return _class[id] ?? const _Named('a class');
  }

  String itemName(Object? id) => _item[id]?.name ?? 'an item';

  String? itemLink(Object? id) {
    final code = _item[id]?.code;
    return code == null || code.isEmpty ? null : '/items/$code';
  }

  String stockCode(Object? id) => _stock[id]?.$1 ?? '';

  String? stockLink(Object? id) {
    final code = _stock[id]?.$1;
    return code == null || code.isEmpty ? null : '/stock/$code';
  }

  Attribute? attribute(Object? id) => _attribute[id];

  String attributeName(Object? id) => _attribute[id]?.name ?? 'an attribute';

  String option(Object? id) => _option[id] ?? 'an option';

  /// An attachment by its title, as history last had it.
  String attachmentTitle(Object? id) =>
      _attachmentTitle['$id'] ?? 'an attachment';

  /// A unit as "mm (Metric length)"; [none] when there is none.
  String unitName(Object? id, [String none = 'none']) => id == null
      ? none
      : _unit[id] == null
      ? 'a unit'
      : unitLabel(_unit[id]!);

  /// A base-unit number as shown in [unitId] ([lock]: Unit lock).
  String _number(num n, int? unitId, bool lock) {
    final unit = _unit[unitId];
    if (unit == null) return formatNumber(n);
    return displayIn(
      Rational.fromNum(n),
      unit,
      _familyUnits[unit.familyId] ?? [unit],
      lock: lock,
    );
  }

  /// A quantity of an item's stock, in its unit: "2", "1.5 m", "uncounted".
  String quantity(Object? item, Object? quantity) {
    if (quantity is! num) return 'uncounted';
    final i = _item[item];
    return _number(quantity, i?.unit, i?.unitLock ?? false);
  }

  /// A typed value of [row] (a value, per-unit value or default), e.g.
  /// "18 V", "yes", "Small". [suffix] is "value" or "default".
  String typed(Json row, Object? attributeId, [String suffix = 'value']) {
    Object? v(String type) => row['${type}_$suffix'];
    final option = v('option');
    if (option != null) return this.option(option);
    final boolean = v('boolean');
    if (boolean is bool) return boolean ? 'yes' : 'no';
    final number = v('integer') ?? v('float');
    if (number is num) {
      final a = _attribute[attributeId];
      return _number(number, a?.unit?.id, a?.unitLock ?? false);
    }
    final text = v('text') ?? v('date');
    return text == null ? '' : '$text';
  }
}

/// The entries of a page, newest first, as actions in words.
List<HistoryEvent> historyEvents(
  List<HistoryEntry> entries,
  HistoryNames names,
  HistoryFocus focus,
) {
  final events = <HistoryEvent>[];
  for (var i = 0; i < entries.length;) {
    var j = i + 1;
    while (j < entries.length &&
        entries[j].transaction == entries[i].transaction) {
      j++;
    }
    final group = entries.sublist(i, j);
    final lines = _Describer(names, focus, group).lines();
    events.add(
      HistoryEvent(
        happenedAt: group.first.happenedAt,
        who: group.first.who,
        whoDeleted: group.first.whoDeleted,
        entries: group,
        lines: lines,
      ),
    );
    i = j;
  }
  return events;
}

/// Shown per action at most; the rest is counted.
const historyLinesShown = 8;

class _Describer {
  _Describer(this.n, this.focus, List<HistoryEntry> group)
    // Oldest first within an action, so "created, then filled" reads in order.
    : entries = group.reversed.toList();

  final HistoryNames n;
  final HistoryFocus focus;
  final List<HistoryEntry> entries;
  final _done = <HistoryEntry>{};

  bool _isFocus(String kind, Object? id) =>
      focus.kind == kind && focus.id == id;

  List<HistoryLine> lines() {
    final out = <HistoryLine>[..._moves(), ..._grids(), ..._treeDeletes()];
    for (final e in entries) {
      if (_done.contains(e)) continue;
      out.addAll(_entry(e));
    }
    if (out.length > historyLinesShown) {
      final more = out.length - (historyLinesShown - 1);
      return [
        ...out.take(historyLinesShown - 1),
        HistoryLine('… and $more more changes'),
      ];
    }
    return out.isEmpty ? const [HistoryLine('No visible change')] : out;
  }

  // --- Actions that change several rows ---

  /// A split or merge: one row loses a quantity that another row of the same
  /// item gains (an existing row, or a new one).
  List<HistoryLine> _moves() {
    final out = <HistoryLine>[];
    final stock = entries.where((e) => e.table == 'stock').toList();
    for (final from in stock) {
      if (_done.contains(from) || from.operation != 'update') continue;
      final q = from.change('quantity');
      final merged = from.marksDeleted && from.data['merged_into'] != null;
      if (!merged && (q == null || q.old is! num || q.now is! num)) continue;
      final amount = merged
          ? from.data['quantity'] as num?
          : (q!.old as num) - (q.now as num);
      if (amount == null || amount <= 0) continue;
      for (final to in stock) {
        if (to == from || _done.contains(to)) continue;
        if (to.data['item'] != from.data['item']) continue;
        final gained = switch (to.operation) {
          'insert' => to.data['quantity'] as num?,
          'update' => switch (to.change('quantity')) {
            (old: num o, now: num v) => v - o,
            _ => null,
          },
          _ => null,
        };
        if (gained != amount) continue;
        _done.addAll([from, to]);
        final item = from.data['item'];
        final what = focus.kind == 'locations'
            ? '${n.quantity(item, amount)} of ${n.itemName(item)}'
            : n.quantity(item, amount);
        final into = to.operation == 'insert'
            ? 'a new row ${n.stockCode(to.rowId)}'
            : 'row ${n.stockCode(to.rowId)}';
        out.add(
          HistoryLine(
            'Moved $what from ${n._loc(from.data['location']).name} to ${n._loc(to.data['location']).name}, into $into',
            n.stockLink(to.rowId),
          ),
        );
        break;
      }
    }
    return out;
  }

  /// A location created with a grid of compartments.
  List<HistoryLine> _grids() {
    final out = <HistoryLine>[];
    for (final box in entries) {
      if (box.table != 'location' || box.operation != 'insert') continue;
      final cells = entries
          .where(
            (e) =>
                e.table == 'location' &&
                e.operation == 'insert' &&
                e.data['parent'] == box.rowId,
          )
          .toList();
      if (cells.length < 2) continue;
      _done.addAll([box, ...cells]);
      final name = '${box.data['name']}';
      final range = '${cells.first.data['name']} … ${cells.last.data['name']}';
      out.add(
        HistoryLine(
          _isFocus('locations', box.rowId)
              ? 'Created with ${cells.length} compartments ($range)'
              : 'Added $name with ${cells.length} compartments ($range)',
          _isFocus('locations', box.rowId) ? null : n._loc(box.rowId).link,
        ),
      );
    }
    return out;
  }

  /// A location or class deleted (or restored) with what was below it.
  List<HistoryLine> _treeDeletes() {
    final out = <HistoryLine>[];
    for (final table in ['location', 'class']) {
      for (final deleted in [true, false]) {
        bool marks(HistoryEntry e) =>
            e.table == table && (deleted ? e.marksDeleted : e.marksRestored);
        final nodes = entries.where(marks).toList();
        if (nodes.length < 2) continue;
        final ids = {for (final e in nodes) e.rowId};
        // The top: the one whose parent wasn't marked with it.
        final top = nodes.firstWhere(
          (e) => !ids.contains(e.data['parent']),
          orElse: () => nodes.first,
        );
        final below = nodes.length - 1;
        final stock = entries
            .where(
              (e) =>
                  e.table == 'stock' &&
                  (deleted ? e.marksDeleted : e.marksRestored),
            )
            .toList();
        final items = entries
            .where(
              (e) =>
                  e.table == 'item' &&
                  (deleted ? e.marksDeleted : e.marksRestored),
            )
            .toList();
        _done.addAll([...nodes, ...stock, ...items]);
        final noun = table == 'location' ? 'location' : 'class';
        final plural = table == 'location' ? 'locations' : 'classes';
        final parts = [
          '$below ${below == 1 ? noun : plural} ${table == 'location' ? 'inside' : 'below'}',
          if (items.isNotEmpty)
            '${items.length} ${items.length == 1 ? 'item' : 'items'}',
          if (stock.isNotEmpty)
            '${stock.length} stock ${stock.length == 1 ? 'row' : 'rows'}',
        ];
        final verb = deleted ? 'Deleted' : 'Restored';
        final self = _isFocus(
          table == 'location' ? 'locations' : 'classes',
          top.rowId,
        );
        final named = table == 'location'
            ? n._loc(top.rowId)
            : n._cls(top.rowId);
        out.add(
          HistoryLine(
            self
                ? '$verb, with ${_join(parts)}'
                : '$verb ${top.data['name']}, with ${_join(parts)}',
            self ? null : named.link,
          ),
        );
      }
    }
    return out;
  }

  // --- One row ---

  List<HistoryLine> _entry(HistoryEntry e) => switch (e.table) {
    'item' => _item(e),
    'value' || 'stock_value' => _value(e),
    'stock' => _stock(e),
    'location' => _node(e, 'locations', 'location'),
    'class' => _node(e, 'classes', 'class'),
    'class_attribute' => _assignment(e),
    'attribute' => _attribute(e),
    'attribute_option' => _option(e),
    'item_attachment' ||
    'stock_attachment' ||
    'location_attachment' ||
    'class_attachment' => _attachment(e),
    'account' => _account(e),
    _ => [HistoryLine('${e.operation} ${e.table}')],
  };

  List<HistoryLine> _item(HistoryEntry e) {
    final self = _isFocus('items', e.rowId);
    final name = '${e.data['name']}';
    final link = self ? null : n.itemLink(e.rowId);
    final subject = self ? '' : 'item $name';
    switch (e.operation) {
      case 'insert':
        return [
          HistoryLine(
            self
                ? 'Created in ${n._cls(e.data['class']).name}'
                : 'Added item $name',
            link,
          ),
        ];
      case 'delete':
        return [HistoryLine(self ? 'Purged' : 'Purged item $name')];
    }
    final out = <HistoryLine>[];
    for (final column in e.changes.keys) {
      final c = e.change(column);
      final line = switch (column) {
        'deleted' =>
          c?.now == true
              ? (self ? 'Deleted' : 'Deleted $subject')
              : (self ? 'Restored' : 'Restored $subject'),
        'name' => 'Renamed from “${c?.old}” to “${c?.now}”',
        'class' =>
          focus.kind == 'classes' && c?.old == focus.id
              ? 'Item $name moved to class ${n._cls(c?.now).name}'
              : focus.kind == 'classes' && c?.now == focus.id
              ? 'Item $name moved here from class ${n._cls(c?.old).name}'
              : 'Moved from class ${n._cls(c?.old).name} to ${n._cls(c?.now).name}',
        'unit' =>
          'Unit: ${n.unitName(c?.old, 'pieces')} → ${n.unitName(c?.now, 'pieces')}',
        'unit_lock' => 'Unit lock ${c?.now == true ? 'on' : 'off'}',
        'photo' => _photo(c?.now),
        _ => null,
      };
      if (line != null) out.add(HistoryLine(line, link));
    }
    return out;
  }

  /// A change of photo: none, or one of the object's attachments.
  String _photo(Object? now) =>
      now == null ? 'Removed the photo' : 'Photo: ${n.attachmentTitle(now)}';

  List<HistoryLine> _value(HistoryEntry e) {
    final attribute = e.data['attribute'];
    final perUnit = e.table == 'stock_value';
    final row = perUnit && focus.kind != 'stock'
        ? ' (row ${n.stockCode(e.data['stock'])})'
        : '';
    final name = '${n.attributeName(attribute)}$row';
    final now = n.typed(e.data, attribute);
    final link = perUnit ? n.stockLink(e.data['stock']) : null;
    switch (e.operation) {
      case 'insert':
        return [HistoryLine('$name: $now', link)];
      case 'delete':
        return [HistoryLine('Cleared $name (was $now)', link)];
    }
    final old = n.typed({
      ...e.data,
      for (final k in e.changes.keys) k: e.change(k)?.old,
    }, attribute);
    return [HistoryLine('$name: $old → $now', link)];
  }

  List<HistoryLine> _stock(HistoryEntry e) {
    final item = e.data['item'];
    final code = n.stockCode(e.rowId);
    final self = _isFocus('stock', e.rowId);
    final link = self ? null : n.stockLink(e.rowId);
    final at = n._loc(e.data['location']).name;
    final qty = n.quantity(item, e.data['quantity']);
    final atFocus = focus.kind == 'locations' && e.data['location'] == focus.id;
    // How the row is named: by item in a location's history, by location
    // in an item's, not at all in its own.
    final row = switch (focus.kind) {
      'stock' => 'the row',
      'locations' => '${n.itemName(item)} ($code)',
      _ => 'row $code',
    };
    switch (e.operation) {
      case 'insert':
        return [
          HistoryLine(switch (focus.kind) {
            'locations' when atFocus =>
              'Added $qty of ${n.itemName(item)} ($code)',
            'locations' => 'Added $qty of ${n.itemName(item)} at $at ($code)',
            'stock' => 'Added $qty at $at',
            _ => 'Added $qty at $at ($code)',
          }, link),
        ];
      case 'delete':
        return [HistoryLine('Purged ${self ? 'it' : row}')];
    }
    final out = <HistoryLine>[];
    final loc = e.change('location');
    if (loc != null) {
      final from = n._loc(loc.old).name, to = n._loc(loc.now).name;
      out.add(
        HistoryLine(switch (focus.kind) {
          'locations' when loc.old == focus.id => '$row moved to $to',
          'locations' when loc.now == focus.id => '$row moved here from $from',
          'stock' => 'Moved from $from to $to',
          _ => 'Moved $row from $from to $to',
        }, link),
      );
    }
    final q = e.change('quantity');
    if (q != null) {
      final text = '${n.quantity(item, q.old)} → ${n.quantity(item, q.now)}';
      out.add(
        HistoryLine(self ? 'Quantity: $text' : 'Quantity of $row: $text', link),
      );
    }
    final it = e.change('item');
    if (it != null) {
      out.add(HistoryLine('Now a row of ${n.itemName(it.now)}', link));
    }
    if (e.changes.containsKey('photo')) {
      out.add(HistoryLine(_photo(e.change('photo')?.now), link));
    }
    final del = e.change('deleted');
    if (del != null) {
      final merged = e.data['merged_into'];
      out.add(
        HistoryLine(
          del.now == true
              ? merged != null
                    ? 'Merged ${self ? 'into' : '$row into'} row ${n.stockCode(merged)} by a move'
                    : self
                    ? 'Deleted ($qty at $at)'
                    : 'Deleted $row ($qty${focus.kind == 'locations' ? '' : ' at $at'})'
              : self
              ? 'Restored'
              : 'Restored $row',
          link,
        ),
      );
    }
    return out;
  }

  List<HistoryLine> _node(HistoryEntry e, String kind, String noun) {
    final self = _isFocus(kind, e.rowId);
    final name = '${e.data['name']}';
    final named = noun == 'location' ? n._loc(e.rowId) : n._cls(e.rowId);
    final link = self ? null : named.link;
    String place(Object? id) => id == null
        ? 'the top'
        : (noun == 'location' ? n._loc(id) : n._cls(id)).name;
    final inside = noun == 'location' ? 'inside' : 'below';
    switch (e.operation) {
      case 'insert':
        return [
          HistoryLine(
            self
                ? 'Created${e.data['parent'] == null ? '' : ' in ${place(e.data['parent'])}'}'
                : 'Added $noun $name ${focus.id == null ? 'at the top' : inside}',
            link,
          ),
        ];
      case 'delete':
        return [HistoryLine(self ? 'Purged' : 'Purged $noun $name')];
    }
    final out = <HistoryLine>[];
    for (final column in e.changes.keys) {
      final c = e.change(column);
      final line = switch (column) {
        'deleted' =>
          '${c?.now == true ? 'Deleted' : 'Restored'}${self ? '' : ' $noun $name'}',
        'name' => 'Renamed from “${c?.old}” to “${c?.now}”',
        'parent' =>
          !self && c?.old == focus.id
              ? '${noun == 'location' ? 'Location' : 'Class'} $name moved to ${place(c?.now)}'
              : !self && c?.now == focus.id
              ? '${noun == 'location' ? 'Location' : 'Class'} $name moved ${focus.id == null ? 'to the top' : 'here'} from ${place(c?.old)}'
              : 'Moved from ${place(c?.old)} to ${place(c?.now)}',
        'container' =>
          c?.now == true ? 'Now a container' : 'No longer a container',
        'photo' => _photo(c?.now),
        _ => null,
      };
      if (line != null) out.add(HistoryLine(line, link));
    }
    return out;
  }

  List<HistoryLine> _assignment(HistoryEntry e) {
    final attribute = e.data['attribute'];
    final name = n.attributeName(attribute);
    final link = '/attributes/$attribute';
    String details(Json row) {
      final def = n.typed(row, attribute, 'default');
      return _join([
        if (def.isNotEmpty) 'default $def',
        if (row['per_unit'] == true) 'per unit',
        if (row['required'] == true) 'required',
      ]);
    }

    switch (e.operation) {
      case 'insert':
        final d = details(e.data);
        return [HistoryLine('Assigned $name${d.isEmpty ? '' : ' ($d)'}', link)];
      case 'delete':
        return [HistoryLine('Unassigned $name', link)];
    }
    final old = details({
      ...e.data,
      for (final k in e.changes.keys) k: e.change(k)?.old,
    });
    final now = details(e.data);
    return [
      HistoryLine(
        '$name: ${old.isEmpty ? 'plain' : old} → ${now.isEmpty ? 'plain' : now}',
        link,
      ),
    ];
  }

  List<HistoryLine> _attribute(HistoryEntry e) {
    final name = '${e.data['name']}';
    // In the history of all attributes, each line names its attribute.
    final self = _isFocus('attributes', e.rowId);
    final subject = self ? '' : ' attribute $name';
    final link = self ? null : '/attributes/${e.rowId}';
    switch (e.operation) {
      case 'insert':
        final unit = e.data['unit'];
        final lock = e.data['unit_lock'] == true ? ', locked' : '';
        return [
          HistoryLine(
            'Created$subject (${self ? '$name, ' : ''}${e.data['datatype']}${unit == null ? '' : ', ${n.unitName(unit)}$lock'})',
            link,
          ),
        ];
      case 'delete':
        return [HistoryLine('Purged$subject')];
    }
    return [
      for (final column in e.changes.keys)
        if (switch (column) {
              'deleted' =>
                '${e.change(column)?.now == true ? 'Deleted' : 'Restored'}$subject',
              'name' =>
                'Renamed from “${e.change(column)?.old}” to “${e.change(column)?.now}”',
              'datatype' =>
                'Type: ${e.change(column)?.old} → ${e.change(column)?.now}',
              'unit' =>
                'Unit: ${n.unitName(e.change(column)?.old)} → ${n.unitName(e.change(column)?.now)}',
              'unit_lock' =>
                'Unit lock ${e.change(column)?.now == true ? 'on' : 'off'}',
              _ => null,
            }
            case final String line)
          HistoryLine(line, link),
    ];
  }

  List<HistoryLine> _option(HistoryEntry e) {
    final name = '${e.data['name']}';
    switch (e.operation) {
      case 'insert':
        return [HistoryLine('Added option $name')];
      case 'delete':
        return [HistoryLine('Purged option $name')];
    }
    return [
      if (e.change('name') case final c?)
        HistoryLine('Renamed option “${c.old}” to “${c.now}”'),
      if (e.change('deleted') case final c?)
        HistoryLine('${c.now == true ? 'Deleted' : 'Restored'} option $name'),
    ];
  }

  /// An attachment of an item, stock row, location or class: added,
  /// renamed, deleted, restored or purged. Lines lead to the attachment, so a
  /// deleted one can be restored from there.
  List<HistoryLine> _attachment(HistoryEntry e) {
    final title = '${e.data['title']}';
    final what = '${e.data['type']}'.startsWith('image/')
        ? 'photo $title'
        : 'file $title';
    final kind = e.table.replaceFirst('_attachment', '');
    final path = switch (kind) {
      'item' => 'items',
      'stock' => 'stock',
      'location' => 'locations',
      _ => 'classes',
    };
    final link = '/attachment/$path/${e.data[kind]}/${e.rowId}';
    switch (e.operation) {
      case 'insert':
        return [HistoryLine('Added $what', link)];
      case 'delete':
        return [HistoryLine('Purged $what')];
    }
    final out = <HistoryLine>[];
    final deleted = e.change('deleted');
    if (deleted != null) {
      out.add(
        HistoryLine(
          '${deleted.now == true ? 'Deleted' : 'Restored'} $what',
          link,
        ),
      );
    }
    final t = e.change('title');
    if (t != null) {
      out.add(HistoryLine('Renamed attachment “${t.old}” to “${t.now}”', link));
    }
    return out;
  }

  List<HistoryLine> _account(HistoryEntry e) {
    switch (e.operation) {
      case 'insert':
        return [HistoryLine('Created account ${e.data['email']}')];
      case 'delete':
        return [const HistoryLine('Purged')];
    }
    final out = <HistoryLine>[];
    for (final column in e.changes.keys) {
      final c = e.change(column);
      final privilege = privilegeKeys[column];
      final line = switch (column) {
        _ when privilege != null =>
          '$privilege: ${privilegeOf(column, c?.old).label} → ${privilegeOf(column, c?.now).label}',
        'email' => 'Email: ${c?.old} → ${c?.now}',
        'password' => 'Password changed',
        'has_password' => c?.now == true ? 'Password set' : 'Password removed',
        'deleted' => c?.now == true ? 'Deleted' : 'Restored',
        _ => null,
      };
      if (line != null) out.add(HistoryLine(line));
    }
    // A password change shows as "password": "changed", not {old, new}.
    if (e.changes['password'] == 'changed' &&
        !out.any((l) => l.text == 'Password changed')) {
      out.add(const HistoryLine('Password changed'));
    }
    return out;
  }
}

String _join(List<String> parts) {
  if (parts.length < 2) return parts.join();
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
