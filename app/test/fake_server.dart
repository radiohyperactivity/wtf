// A pretend wtfd for the widget tests: a few classes with attributes,
// locations, one item with stock, and the answers of the API calls the app
// makes. It records the requests that change something.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _headers = {'content-type': 'application/json', 'api-revision': '1'};

typedef JsonMap = Map<String, dynamic>;

class FakeServer {
  FakeServer({this.role = 'admin'});

  /// The role of the account: viewer, user or admin.
  final String role;

  /// Requests that changed something: "POST /api/v1/stock {…}". Dry runs
  /// too, with ?dry_run=true.
  final List<String> changes = [];

  /// The body of the login, as sent.
  JsonMap? login;

  // --- The data ---

  final classes = <JsonMap>[
    {'id': 'c-tools', 'name': 'Tools', 'parent': null, 'container': true},
    {
      'id': 'c-drills',
      'name': 'Drills',
      'parent': 'c-tools',
      'container': false,
    },
  ];

  /// The attributes each class defines itself, by name; the classes below
  /// it inherit them.
  final own = <String, Map<String, JsonMap>>{
    'c-tools': {
      'Colour': {
        'scope': 'item',
        'type': 'choice',
        'required': false,
        'choices': ['Red', 'Green', 'Blue'],
        'default': 'Red',
        'order': 1,
      },
    },
    'c-drills': {
      'Voltage': {
        'scope': 'item',
        'type': 'decimal',
        'required': true,
        'unit': 'V',
        'order': 2,
      },
      'Manual': {'scope': 'item', 'type': 'url', 'required': false, 'order': 3},
      'Datasheet': {
        'scope': 'item',
        'type': 'attachment',
        'required': false,
        'media': ['application/pdf'],
        'order': 4,
      },
      'Bought': {
        'scope': 'stock',
        'type': 'date',
        'required': false,
        'order': 1,
      },
    },
  };

  final locations = <JsonMap>[
    {
      'id': 'l-garage',
      'code': '1A00',
      'name': 'Garage',
      'parent': null,
      'container': true,
    },
    {
      'id': 'l-shelf1',
      'code': '1A01',
      'name': 'Shelf 1',
      'parent': 'l-garage',
      'container': false,
    },
    {
      'id': 'l-shelf2',
      'code': '1A02',
      'name': 'Shelf 2',
      'parent': 'l-garage',
      'container': false,
    },
  ];
  final items = <JsonMap>[
    {
      'id': 'i-drill',
      'code': '1B00',
      'name': 'Cordless drill',
      'class': 'c-drills',
      'unit': null,
      'photo': null,
      'values': <String, Object?>{'Voltage': 18, 'Colour': 'Red'},
      'defaulted': <String>['Colour'],
    },
  ];
  final stock = <JsonMap>[
    {
      'id': 's-1',
      'code': '1C00',
      'item': 'i-drill',
      'location': 'l-shelf1',
      'amount': 2,
      'reference': null,
      'serial': null,
      'photo': null,
      'values': <String, Object?>{},
      'defaulted': <String>[],
    },
  ];

  /// The accounts besides the logged-in one.
  final accounts = <JsonMap>[
    {
      'id': 'a2',
      'email': 'bob@example.com',
      'has_password': true,
      'role': 'user',
    },
  ];

  /// Label codes that were handed out to something since deleted.
  final gone = <String>{};

  /// The account's sessions.
  final sessions = <JsonMap>[
    {
      'id': 'sess-this',
      'client': 'WtF on Windows',
      'created': '2026-11-01T10:00:00Z',
      'last_used': '2026-11-04T09:00:00Z',
      'max_idle': 2592000,
      'expires': '2026-12-04T09:00:00Z',
      'current': true,
      'usage': [
        {'address': '192.168.1.20', 'seen': '2026-11-04T09:00:00Z'},
      ],
    },
    {
      'id': 'sess-phone',
      'client': 'WtF on Android',
      'created': '2026-10-01T10:00:00Z',
      'last_used': '2026-11-02T18:30:00Z',
      'max_idle': null,
      'expires': null,
      'current': false,
      'usage': [
        {'address': '10.0.0.7', 'seen': '2026-11-02T18:30:00Z'},
      ],
    },
  ];

  int _next = 0;
  int _nextId = 0;

  String _id(String prefix) => '$prefix-new${_nextId++}';

  String _code(String prefix) =>
      '$prefix${(_next++).toString().padLeft(2, '0')}';

  // --- JSON as the API writes it ---

  List<JsonMap> _tree(List<JsonMap> nodes, String? parent) => [
    for (final n in nodes.where((n) => n['parent'] == parent))
      {...n, 'children': _tree(nodes, n['id'] as String)},
  ];

  List<JsonMap> _path(List<JsonMap> nodes, String id) {
    final out = <JsonMap>[];
    for (String? at = id; at != null;) {
      final n = nodes.firstWhere((n) => n['id'] == at);
      out.insert(0, {'id': n['id'], 'name': n['name']});
      at = n['parent'] as String?;
    }
    return out;
  }

  /// [id] and the nodes below it.
  Set<String> _subtree(List<JsonMap> nodes, String id) => {
    for (final n in nodes)
      if (_path(nodes, n['id'] as String).any((p) => p['id'] == id))
        n['id'] as String,
  };

  /// Every attribute class [id] has, its own and inherited, by name.
  Map<String, JsonMap> attributesOf(String id) => {
    for (final p in _path(classes, id))
      for (final MapEntry(:key, :value) in (own[p['id']] ?? {}).entries)
        key: {...value, 'class': p['id'], 'inherited': p['id'] != id},
  };

  /// The class that defines attribute [name] of class [id].
  JsonMap? _attribute(String id, String name) => attributesOf(id)[name];

  JsonMap classJson(String id) {
    final c = classes.firstWhere((c) => c['id'] == id);
    final attributes =
        [
          for (final MapEntry(:key, :value) in attributesOf(id).entries)
            {'name': key, ...value},
        ]..sort((a, b) {
          final scope = (a['scope'] as String).compareTo(b['scope'] as String);
          return scope != 0
              ? scope
              : (a['order'] as int).compareTo(b['order'] as int);
        });
    return {...c, 'path': _path(classes, id), 'attributes': attributes};
  }

  JsonMap locationJson(String id) => {
    ...locations.firstWhere((l) => l['id'] == id),
    'path': _path(locations, id),
  };

  JsonMap _summary(JsonMap i) => {
    for (final k in ['id', 'code', 'name', 'class', 'unit', 'photo']) k: i[k],
  };

  JsonMap _stockRow(
    JsonMap s, {
    bool withItem = true,
    bool withValues = true,
  }) => {
    for (final k in [
      'id',
      'code',
      'location',
      'amount',
      'reference',
      'serial',
      'photo',
    ])
      k: s[k],
    'item': withItem
        ? _summary(items.firstWhere((i) => i['id'] == s['item']))
        : s['item'],
    if (withValues) ...{'values': s['values'], 'defaulted': s['defaulted']},
  };

  JsonMap itemJson(String id) {
    final i = items.firstWhere((i) => i['id'] == id);
    final c = classJson(i['class'] as String);
    return {
      ..._summary(i),
      'class': {'id': c['id'], 'name': c['name'], 'path': c['path']},
      'values': i['values'],
      'defaulted': i['defaulted'],
      'stock': [
        for (final s in stock.where((s) => s['item'] == id))
          _stockRow(s, withItem: false),
      ],
    };
  }

  JsonMap stockJson(String id) =>
      _stockRow(stock.firstWhere((s) => s['id'] == id));

  JsonMap _listed(JsonMap i) {
    final rows = stock.where((s) => s['item'] == i['id']);
    return {
      ..._summary(i),
      'stock': {
        'total': rows.fold<num>(0, (t, s) => t + (s['amount'] as num? ?? 0)),
        'uncounted': rows.any((s) => s['amount'] == null),
      },
    };
  }

  JsonMap get me => {
    'id': 'a1',
    'email': 'anna@example.com',
    'has_password': true,
    'role': role,
  };

  /// The where filters of the last GET /items, as sent.
  String? lastWhere;

  /// The `after` of each GET /items, in order.
  final List<String?> itemPages = [];

  /// A filter on an item's own value, as the server compares them.
  bool _matches(JsonMap item, JsonMap f) {
    final v = (item['values'] as Map)[f['attribute']];
    final x = f['value'];
    return switch ((f['op'], v)) {
      ('=', _) =>
        v is String && x is String
            ? v.toLowerCase() == x.toLowerCase()
            : v == x,
      ('in', String s) => (x as List).any(
        (c) => '$c'.toLowerCase() == s.toLowerCase(),
      ),
      ('contains', String s) => s.toLowerCase().contains('$x'.toLowerCase()),
      ('>', num n) => n > (x as num),
      ('>=', num n) => n >= (x as num),
      ('<', num n) => n < (x as num),
      ('<=', num n) => n <= (x as num),
      ('between', num n) => n >= (x as List)[0] && n <= x[1],
      _ => false,
    };
  }

  /// A page of [rows], by key: those after [after], at most [limit].
  JsonMap _page(List<JsonMap> rows, String? after, int limit) {
    final start = after == null
        ? 0
        : rows.indexWhere((r) => r['id'] == after) + 1;
    final page = rows.skip(start).take(limit).toList();
    final more = start + page.length < rows.length;
    return {'rows': page, 'more': more, 'next': more ? page.last['id'] : null};
  }

  /// Sets the values of a row (an item or a stock row) of class [classId],
  /// as a patch does: `values` (null removes one), then `default`.
  void _patchValues(JsonMap row, String classId, JsonMap body) {
    final values = row['values'] as Map<String, Object?>;
    final defaulted = row['defaulted'] as List<String>;
    for (final MapEntry(:key, :value)
        in ((body['values'] as Map?) ?? {}).entries) {
      if (value == null) {
        values.remove(key);
      } else {
        values[key as String] = value;
      }
      defaulted.remove(key);
    }
    for (final name in (body['default'] as List?) ?? const []) {
      values[name as String] = _attribute(classId, name)!['default'];
      if (!defaulted.contains(name)) defaulted.add(name);
    }
  }

  /// A new row's values: those given, and the defaults of the rest.
  (Map<String, Object?>, List<String>) _newValues(
    String classId,
    String scope,
    Map? given,
  ) {
    final values = <String, Object?>{
      for (final MapEntry(:key, :value) in (given ?? {}).entries)
        key as String: ?value,
    };
    final defaulted = <String>[];
    for (final MapEntry(:key, :value) in attributesOf(classId).entries) {
      if (value['scope'] == scope &&
          !values.containsKey(key) &&
          value.containsKey('default')) {
        values[key] = value['default'];
        defaulted.add(key);
      }
    }
    return (values, defaulted);
  }

  /// The items of class [id] and the classes below it.
  List<JsonMap> _itemsBelow(String id) {
    final ids = _subtree(classes, id);
    return [
      for (final i in items)
        if (ids.contains(i['class'])) i,
    ];
  }

  /// A change of class [id]'s attributes: done unless [dryRun], and how
  /// many items it rewrote (or would have).
  http.Response _change(String id, bool dryRun, int Function() change) {
    final saved = jsonEncode([own, items]);
    final count = change();
    if (dryRun) {
      // As the server undoes a dry run.
      final [o, i] = jsonDecode(saved) as List;
      own
        ..clear()
        ..addAll({
          for (final MapEntry(:key, :value) in (o as Map).entries)
            key as String: {
              for (final MapEntry(:key, :value) in (value as Map).entries)
                key as String: value as JsonMap,
            },
        });
      for (final (n, item) in (i as List).indexed) {
        items[n]
          ..['values'] = <String, Object?>{...(item as Map)['values'] as Map}
          ..['defaulted'] = <String>[...(item['defaulted'] as List).cast()];
      }
    }
    return _json({
      'class': classJson(id),
      'items': count,
      'stock': 0,
      'dry_run': dryRun,
    });
  }

  // --- Requests ---

  http.Response _json(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _headers);

  http.Response _problem(int status, String title, [String detail = '']) =>
      _json({
        'type': status == 410 ? '/problems/gone' : '/problems/x',
        'title': title,
        'status': status,
        'detail': detail,
      }, status);

  http.Response get _noContent => http.Response('', 204, headers: _headers);

  /// A file's content, as wtfd sends it.
  http.Response _file(String name, String type) => http.Response.bytes(
    [1, 2, 3],
    200,
    headers: {
      ..._headers,
      'content-type': type,
      'content-disposition': 'attachment; filename=$name',
    },
  );

  late final http.Client client = MockClient((req) async {
    final path = req.url.path.replaceFirst('/api/v1', '');
    final q = req.url.queryParameters;
    final method = req.method;
    final dryRun = q['dry_run'] == 'true';
    if (method != 'GET' && path != '/login') {
      changes.add(
        '$method ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''} ${req.body}'
            .trim(),
      );
    }
    final multipart =
        req.headers['content-type']?.startsWith('multipart/') ?? false;
    final body = req.body.isEmpty || multipart
        ? null
        : jsonDecode(req.body) as JsonMap;
    final segments = req.url.pathSegments.skip(2).toList();

    if (path == '/login') {
      login = body;
      return http.Response(
        jsonEncode({'account': me}),
        200,
        headers: {
          ..._headers,
          'set-cookie': 'wtf_session=tok; Path=/api; Max-Age=2592000; HttpOnly',
        },
      );
    }
    if (req.headers['Cookie'] != 'wtf_session=tok') {
      return _problem(401, 'Not authenticated');
    }

    switch ((method, segments)) {
      case ('GET', ['me']):
        return _json(me);
      case ('POST', ['logout']):
        return http.Response(
          '',
          204,
          headers: {
            ..._headers,
            'set-cookie': 'wtf_session=; Path=/api; Max-Age=0',
          },
        );
      case ('GET', ['me', 'sessions']):
        return _json(sessions);
      case ('DELETE', ['me', 'sessions', final id]):
        sessions.removeWhere((s) => s['id'] == id);
        return _noContent;
      case ('POST', ['me', 'sessions', 'logout-others']):
        final ended = sessions.where((s) => s['current'] != true).length;
        sessions.removeWhere((s) => s['current'] != true);
        return _json({'ended': ended});
      case ('PUT', ['me', 'password']):
        return _noContent;
      case ('GET', ['accounts']):
        return _json([me, ...accounts]);
      case ('GET', ['accounts', final id]):
        return _json([me, ...accounts].firstWhere((a) => a['id'] == id));
      case ('PATCH', ['accounts', final id]):
        final a = accounts.firstWhere((a) => a['id'] == id);
        if (body!.containsKey('password')) {
          a['has_password'] = body['password'] != null;
        }
        return _json(a);

      case ('GET', ['classes']):
        return _json({'version': 1, 'tree': _tree(classes, null)});
      case ('GET', ['locations']):
        return _json({'version': 1, 'tree': _tree(locations, null)});
      case ('GET', ['classes', final id]):
        return _json(classJson(id));
      case ('GET', ['locations', final id]):
        return _json(locationJson(id));

      // A class's attributes.
      case ('POST', ['classes', final id, 'attributes']):
        final name = body!['name'] as String;
        const fixed = {'name', 'class', 'unit', 'photo', 'amount', 'serial'};
        if (fixed.contains(name.toLowerCase())) {
          return _problem(400, 'Invalid input', '"$name" is a fixed field');
        }
        final def = body['definition'] as JsonMap;
        return _change(id, dryRun, () {
          (own[id] ??= {})[name] = {...def, 'order': def['order'] ?? 9};
          var n = 0;
          if (def['scope'] == 'item' && def.containsKey('default')) {
            for (final i in _itemsBelow(id)) {
              if ((i['values'] as Map).containsKey(name)) continue;
              (i['values'] as Map)[name] = def['default'];
              (i['defaulted'] as List).add(name);
              n++;
            }
          }
          return n;
        });
      case ('PATCH', ['classes', final id, 'attributes', final name]):
        return _change(id, dryRun, () {
          final def = own[id]![name]!;
          for (final MapEntry(:key, :value) in body!.entries) {
            value == null ? def.remove(key) : def[key] = value;
          }
          var n = 0;
          if (body.containsKey('default')) {
            for (final i in _itemsBelow(id)) {
              if (!(i['defaulted'] as List).contains(name)) continue;
              (i['values'] as Map)[name] = body['default'];
              n++;
            }
          }
          return n;
        });
      case ('POST', ['classes', final id, 'attributes', final name, 'rename']):
        return _change(id, dryRun, () {
          final to = body!['name'] as String;
          own[id]![to] = own[id]!.remove(name)!;
          var n = 0;
          for (final i in _itemsBelow(id)) {
            final values = i['values'] as Map;
            if (!values.containsKey(name)) continue;
            values[to] = values.remove(name);
            final d = i['defaulted'] as List;
            if (d.remove(name)) d.add(to);
            n++;
          }
          return n;
        });
      case ('DELETE', ['classes', final id, 'attributes', final name]):
        return _change(id, dryRun, () {
          own[id]!.remove(name);
          var n = 0;
          for (final i in _itemsBelow(id)) {
            if ((i['values'] as Map).remove(name) != null) n++;
            (i['defaulted'] as List).remove(name);
          }
          return n;
        });
      case ('POST', ['classes', final id, 'attributes', final name, 'choices']):
        return _change(id, dryRun, () {
          (own[id]![name]!['choices'] as List).add(body!['choice']);
          return 0;
        });
      case (
        'DELETE',
        [
          'classes',
          final id,
          'attributes',
          final name,
          'choices',
          final choice,
        ],
      ):
        final users = _itemsBelow(id)
            .where((i) => (i['values'] as Map)[name] == choice)
            .length;
        if (users > 0) {
          return _problem(
            409,
            'In use',
            '$users ${users == 1 ? 'item has' : 'items have'} "$choice"',
          );
        }
        return _change(id, dryRun, () {
          (own[id]![name]!['choices'] as List).remove(choice);
          return 0;
        });
      case (
        'POST',
        [
          'classes',
          final id,
          'attributes',
          final name,
          'choices',
          final choice,
          'rename',
        ],
      ):
        return _change(id, dryRun, () {
          final to = body!['choice'];
          final choices = own[id]![name]!['choices'] as List;
          choices[choices.indexOf(choice)] = to;
          var n = 0;
          for (final i in _itemsBelow(id)) {
            final values = i['values'] as Map;
            if (values[name] != choice) continue;
            values[name] = to;
            n++;
          }
          return n;
        });

      case ('GET', ['items']):
        lastWhere = q['where'];
        itemPages.add(q['after']);
        final where = q['where'] == null
            ? const <JsonMap>[]
            : (jsonDecode(q['where']!) as List).cast<JsonMap>();
        final words = (q['search'] ?? '')
            .toLowerCase()
            .split(' ')
            .where((w) => w.isNotEmpty);
        final inClass = q['class'] == null
            ? null
            : _subtree(classes, q['class']!);
        final found = items.where((i) {
          final classPath = _path(
            classes,
            i['class'] as String,
          ).map((p) => p['name']).join(' ');
          final text = '${i['name']} $classPath'.toLowerCase();
          return words.every(text.contains) &&
              (inClass == null || inClass.contains(i['class'])) &&
              where.every((f) => _matches(i, f));
        }).toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
        return _json(
          _page(
            found.map(_listed).toList(),
            q['after'],
            int.parse(q['limit'] ?? '100'),
          ),
        );
      case ('GET', ['items', final id]):
        return _json(itemJson(id));
      case ('POST', ['items']):
        final (values, defaulted) = _newValues(
          body!['class'] as String,
          'item',
          body['values'] as Map?,
        );
        final item = {
          'id': _id('i'),
          'code': _code('1D'),
          'name': body['name'],
          'class': body['class'],
          'unit': body['unit'],
          'photo': null,
          'values': values,
          'defaulted': defaulted,
        };
        items.add(item);
        return _json(itemJson(item['id'] as String), 201);
      case ('PATCH', ['items', final id]):
        final item = items.firstWhere((i) => i['id'] == id);
        for (final k in ['name', 'class', 'unit', 'photo']) {
          if (body!.containsKey(k)) item[k] = body[k];
        }
        _patchValues(item, item['class'] as String, body!);
        return _json(itemJson(id));
      case ('DELETE', ['items', final id]):
        if (stock.any((s) => s['item'] == id)) {
          return _problem(409, 'In use', 'It has stock');
        }
        items.removeWhere((i) => i['id'] == id);
        return _noContent;

      // Files: the photo, and the file of an attachment attribute.
      case ('PUT', [final kind, final id, 'photo']):
        final row = (kind == 'items' ? items : stock).firstWhere(
          (r) => r['id'] == id,
        );
        row['photo'] = 'hash-${_nextId++}';
        return _json(kind == 'items' ? itemJson(id) : stockJson(id));
      case ('PUT', [final kind, final id, 'files', final name]):
        final row = (kind == 'items' ? items : stock).firstWhere(
          (r) => r['id'] == id,
        );
        (row['values'] as Map)[name] = 'hash-${_nextId++}';
        return _json(kind == 'items' ? itemJson(id) : stockJson(id));
      case ('GET', [_, _, 'photo']):
        return _file('Photo.png', 'image/png');
      case ('GET', [_, _, 'files', final name]):
        return _file('$name.pdf', 'application/pdf');

      case ('GET', ['stock']):
        final rows = stock.where((s) {
          if (q['item'] != null && s['item'] != q['item']) return false;
          if (q['location'] != null &&
              !_subtree(locations, q['location']!).contains(s['location'])) {
            return false;
          }
          return true;
        }).toList();
        return _json(
          _page(
            [for (final s in rows) _stockRow(s, withValues: false)],
            q['after'],
            int.parse(q['limit'] ?? '100'),
          ),
        );
      case ('GET', ['stock', final id]):
        return _json(stockJson(id));
      case ('POST', ['stock']):
        final item = items.firstWhere((i) => i['id'] == body!['item']);
        final (values, defaulted) = _newValues(
          item['class'] as String,
          'stock',
          body!['values'] as Map?,
        );
        final row = {
          'id': _id('s'),
          'code': _code('1E'),
          'item': body['item'],
          'location': body['location'],
          'amount': body['amount'],
          'reference': body['reference'],
          'serial': body['serial'],
          'photo': null,
          'values': values,
          'defaulted': defaulted,
        };
        stock.add(row);
        return _json(stockJson(row['id'] as String), 201);
      case ('PATCH', ['stock', final id]):
        final row = stock.firstWhere((s) => s['id'] == id);
        for (final k in [
          'item',
          'location',
          'amount',
          'reference',
          'serial',
          'photo',
        ]) {
          if (body!.containsKey(k)) row[k] = body[k];
        }
        final item = items.firstWhere((i) => i['id'] == row['item']);
        _patchValues(row, item['class'] as String, body!);
        return _json(stockJson(id));
      case ('DELETE', ['stock', final id]):
        gone.add(stock.firstWhere((s) => s['id'] == id)['code'] as String);
        stock.removeWhere((s) => s['id'] == id);
        return _noContent;
      case ('POST', ['stock', final id, 'move']):
        final s = stock.firstWhere((s) => s['id'] == id);
        final amount = body!['amount'] as num?;
        if (amount == null || amount == s['amount']) {
          s['location'] = body['location'];
          return _json(stockJson(id));
        }
        s['amount'] = (s['amount'] as num) - amount;
        final row = {
          ...s,
          'id': _id('s'),
          'code': _code('1E'),
          'location': body['location'],
          'amount': amount,
          'values': <String, Object?>{...s['values'] as Map},
          'defaulted': <String>[...(s['defaulted'] as List).cast()],
        };
        stock.add(row);
        return _json(stockJson(row['id'] as String));
      case ('POST', ['stock', final id, 'merge']):
        final from = stock.firstWhere((s) => s['id'] == id);
        final into = stock.firstWhere((s) => s['id'] == body!['into']);
        final resolve = (body!['resolve'] as Map?) ?? const {};
        final fromValues = from['values'] as Map;
        final intoValues = into['values'] as Map;
        final differences = [
          for (final k in ['reference', 'serial', 'photo'])
            if (from[k] != into[k]) k,
          for (final name in {...fromValues.keys, ...intoValues.keys})
            if (fromValues[name] != intoValues[name]) 'values.$name',
        ];
        final open = [
          for (final d in differences)
            if (d.startsWith('values.')
                ? !((resolve['values'] as Map?) ?? {}).containsKey(
                    d.substring(7),
                  )
                : !resolve.containsKey(d))
              d,
        ];
        if (open.isNotEmpty) {
          return _problem(
            422,
            'Not allowed',
            'The rows differ in ${open.join(', ')}; say for each which row\'s to keep',
          );
        }
        for (final d in differences) {
          if (d.startsWith('values.')) {
            final name = d.substring(7);
            if ((resolve['values'] as Map)[name] == 'from') {
              intoValues[name] = fromValues[name];
            }
          } else if (resolve[d] == 'from') {
            into[d] = from[d];
          }
        }
        final amount = (body['amount'] as num?) ?? from['amount'] as num;
        into['amount'] = (into['amount'] as num) + amount;
        if (amount == from['amount']) {
          gone.add(from['code'] as String);
          stock.remove(from);
        } else {
          from['amount'] = (from['amount'] as num) - amount;
        }
        return _json(stockJson(into['id'] as String));

      case ('GET', ['codes', final code]):
        if (gone.contains(code)) {
          return _problem(
            410,
            'Gone',
            'Its item, stock row or location has been deleted',
          );
        }
        for (final l in locations) {
          if (l['code'] == code) {
            return _json({
              'type': 'location',
              'object': locationJson(l['id'] as String),
            });
          }
        }
        for (final i in items) {
          if (i['code'] == code) {
            return _json({
              'type': 'item',
              'object': itemJson(i['id'] as String),
            });
          }
        }
        for (final s in stock) {
          if (s['code'] == code) {
            return _json({
              'type': 'stock',
              'object': stockJson(s['id'] as String),
            });
          }
        }
        return _problem(404, 'Not found');

      case ('POST', ['model', 'import']):
        // As the server reports a new MCU model, of which one attribute is
        // there already; a dry run keeps nothing.
        return _json({
          'classes': {'added': 1, 'existing': 0},
          'attributes': {'added': 2, 'existing': 1},
          'items': 0,
          'stock': 0,
          'dry_run': dryRun,
        });
      case ('GET', ['classes', _, 'model']):
        // The keys in the format's order, as the server writes them.
        return http.Response(
          '{"format": "wtf-model", "version": 2, '
          '"meta": {"name": "Drills"}, '
          '"classes": [{"name": "Drills", "attributes": '
          '{"Voltage": {"scope": "item", "type": "decimal", "unit": "V"}}}]}',
          200,
          headers: _headers,
        );

      case ('GET', ['locations', final id, 'deletion']):
        final ids = _subtree(locations, id);
        final below = locations.where((l) => ids.contains(l['id'])).toList();
        return _json({
          'locations': [
            for (final l in below.reversed)
              {
                'id': l['id'],
                'code': l['code'],
                'path': _path(
                  locations,
                  l['id'] as String,
                ).map((p) => p['name']).join('/'),
              },
          ],
          'stock': [
            for (final s in stock.where((s) => ids.contains(s['location'])))
              {
                'id': s['id'],
                'code': s['code'],
                'item': {
                  'id': s['item'],
                  'code': '1B00',
                  'name': 'Cordless drill',
                },
                'location': s['location'],
                'amount': s['amount'],
              },
          ],
        });
      case ('DELETE', ['locations', final id]):
        final ids = _subtree(locations, id);
        final used = stock.any((s) => ids.contains(s['location']));
        if (used && q['force'] != 'true') return _problem(409, 'In use');
        for (final l in locations.where((l) => ids.contains(l['id']))) {
          gone.add(l['code'] as String);
        }
        locations.removeWhere((l) => ids.contains(l['id']));
        stock.removeWhere((s) => ids.contains(s['location']));
        return _noContent;
      case ('POST', ['locations']):
        final l = {
          'id': _id('l'),
          'code': _code('1F'),
          'name': body!['name'],
          'parent': body['parent'],
          'container': body['grid'] != null || body['container'] == true,
        };
        locations.add(l);
        final grid = body['grid'] as Map?;
        if (grid != null) {
          for (var r = 1; r <= (grid['rows'] as int); r++) {
            for (var c = 0; c < (grid['columns'] as int); c++) {
              locations.add({
                'id': _id('l'),
                'code': _code('1G'),
                'name': '${String.fromCharCode(65 + c)}$r',
                'parent': l['id'],
                'container': false,
              });
            }
          }
        }
        return _json(locationJson(l['id'] as String), 201);
    }
    return _problem(404, 'Not found: $method $path');
  });
}
