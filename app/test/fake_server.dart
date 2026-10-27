// A pretend wtfd for the widget tests: a few classes, locations, one item
// with stock, and the answers of the API calls the app makes. It records
// the requests that change something.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _headers = {'content-type': 'application/json', 'api-revision': '2'};

class FakeServer {
  FakeServer({this.privilege = 'read_write'});

  /// The data and model privilege of the account.
  final String privilege;

  /// Requests that changed something: "POST /api/v1/stock {…}".
  final List<String> changes = [];

  /// History pages by route, e.g. "items/i-drill": the entries, newest first.
  final Map<String, List<Map<String, dynamic>>> history = {};

  // --- The data ---

  final volt = {
    'id': 'u-v',
    'name': 'volt',
    'symbol': 'V',
    'is_base': true,
    'base_factor': 1,
    'base_offset': 0,
  };
  final millivolt = {
    'id': 'u-mv',
    'name': 'millivolt',
    'symbol': 'mV',
    'is_base': false,
    'base_factor': 0.001,
    'base_offset': 0,
  };
  late final quantity = {'id': 'q-v', 'name': 'Voltage', 'datatype': 'float'};
  late final group = {
    'id': 'g-v',
    'name': 'Voltage',
    'quantity': quantity,
    'base_unit': volt,
  };
  late final voltage = {
    'id': 'a-volt',
    'name': 'Voltage',
    'datatype': 'float',
    'unit_group': group,
  };

  final classes = <Map<String, dynamic>>[
    {'id': 'c-tools', 'name': 'Tools', 'parent': null, 'container': true},
    {
      'id': 'c-drills',
      'name': 'Drills',
      'parent': 'c-tools',
      'container': false,
    },
  ];
  final locations = <Map<String, dynamic>>[
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
  final items = <Map<String, dynamic>>[
    {
      'id': 'i-drill',
      'code': '1B00',
      'name': 'Cordless drill',
      'class': 'c-drills',
      'unit_group': null,
      'values': <String, Object?>{'a-volt': 18},
    },
  ];
  final stock = <Map<String, dynamic>>[
    {
      'id': 's-1',
      'code': '1C00',
      'item': 'i-drill',
      'location': 'l-shelf1',
      'quantity': 2,
    },
  ];
  int _next = 0;
  int _nextId = 0;

  String _id(String prefix) => '$prefix-new${_nextId++}';

  String _code(String prefix) =>
      '$prefix${(_next++).toString().padLeft(2, '0')}';

  // --- JSON as the API writes it ---

  List<Map<String, dynamic>> _tree(
    List<Map<String, dynamic>> nodes,
    String? parent,
  ) => [
    for (final n in nodes.where(
      (n) => n['parent'] == parent && n['deleted'] != true,
    ))
      {...n, 'children': _tree(nodes, n['id'] as String)},
  ];

  List<Map<String, dynamic>> _path(
    List<Map<String, dynamic>> nodes,
    String id,
  ) {
    final out = <Map<String, dynamic>>[];
    for (String? at = id; at != null;) {
      final n = nodes.firstWhere((n) => n['id'] == at);
      out.insert(0, {'id': n['id'], 'name': n['name']});
      at = n['parent'] as String?;
    }
    return out;
  }

  Map<String, dynamic> classJson(String id) {
    final c = classes.firstWhere((c) => c['id'] == id);
    return {
      ...c,
      'path': _path(classes, id),
      'attributes': [
        if (id == 'c-drills')
          {
            'attribute': voltage,
            'defined_on_class': 'c-drills',
            'inherited': false,
            'default': null,
            'per_unit': false,
            'required': true,
          },
      ],
      'attachments': [],
    };
  }

  Map<String, dynamic> locationJson(String id) => {
    'deleted': false,
    ...locations.firstWhere((l) => l['id'] == id),
    'path': _path(locations, id),
    'attachments': [],
  };

  Map<String, dynamic> _summary(Map<String, dynamic> i) => {
    'id': i['id'],
    'code': i['code'],
    'name': i['name'],
    'class': i['class'],
    'unit_group': null,
  };

  List<Map<String, dynamic>> _values(Map<String, dynamic> i) => [
    for (final MapEntry(:key, :value) in (i['values'] as Map).entries)
      if (key == 'a-volt')
        {
          'attribute': voltage,
          'value': value,
          'unit': volt,
          'display': {'value': value, 'unit': volt},
          'is_default': false,
        },
  ];

  Map<String, dynamic> itemJson(String id) {
    final i = items.firstWhere((i) => i['id'] == id);
    return {
      ..._summary(i),
      'class': classJson(i['class'] as String)..remove('attributes'),
      'values': _values(i),
      'missing': [],
      'photo': null,
      'attachments': [],
      'stock': [
        for (final s in stock.where((s) => s['item'] == id))
          {
            ...s,
            'display': null,
            'values': [],
            'missing': [],
            'attachments': [],
          },
      ],
    };
  }

  Map<String, dynamic> stockJson(String id) {
    final s = stock.firstWhere((s) => s['id'] == id);
    final i = items.firstWhere((i) => i['id'] == s['item']);
    return {
      ...s,
      'item': _summary(i),
      'unit': null,
      'display': null,
      'values': [],
      'missing': [],
      'attachments': [],
    };
  }

  Map<String, dynamic> _listed(Map<String, dynamic> i) {
    final rows = stock.where((s) => s['item'] == i['id']);
    return {
      ..._summary(i),
      'stock': {
        'total': rows.fold<num>(0, (t, s) => t + (s['quantity'] as num? ?? 0)),
        'unit': null,
        'display': null,
        'uncounted': rows.any((s) => s['quantity'] == null),
      },
      'incomplete': false,
      'photo': null,
    };
  }

  Map<String, dynamic> get me => {
    'id': 'a1',
    'email': 'anna@example.com',
    'data_privilege': privilege,
    'model_privilege': privilege,
    'account_privilege': 'none',
    'history_privilege': 'read_only',
    'tenant': {'id': 't1', 'name': 'Home', 'hostname': 'wtf.test'},
  };

  // --- Requests ---

  http.Response _json(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _headers);

  http.Response _problem(int status, String title) =>
      _json({'type': '/problems/x', 'title': title, 'status': status}, status);

  late final http.Client client = MockClient((req) async {
    final path = req.url.path.replaceFirst('/api/v1', '');
    final q = req.url.queryParameters;
    final method = req.method;
    if (method != 'GET' && path != '/login') {
      changes.add(
        '$method ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''} ${req.body}'
            .trim(),
      );
    }
    final body = req.body.isEmpty
        ? null
        : jsonDecode(req.body) as Map<String, dynamic>;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();

    if (path == '/login') {
      return http.Response(
        jsonEncode({'account': me..remove('tenant'), 'tenant': me['tenant']}),
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
      case ('GET', ['classes']):
        return _json({'version': 1, 'tree': _tree(classes, null)});
      case ('GET', ['locations']):
        return _json({'version': 1, 'tree': _tree(locations, null)});
      case ('GET', ['classes', final id]):
        return _json(classJson(id));
      case ('GET', ['locations', final id]):
        return _json(locationJson(id));
      case ('GET', ['items']):
        final words = (q['search'] ?? '')
            .toLowerCase()
            .split(' ')
            .where((w) => w.isNotEmpty);
        final found = items.where((i) {
          final classPath = _path(
            classes,
            i['class'] as String,
          ).map((p) => p['name']).join(' ');
          final text = '${i['name']} $classPath'.toLowerCase();
          return words.every(text.contains) &&
              (q['class'] == null || i['class'] == q['class']);
        }).toList();
        return _json({
          'total': found.length,
          'limit': 50,
          'offset': 0,
          'rows': found.map(_listed).toList(),
        });
      case ('GET', ['items', final id]):
        return _json(itemJson(id));
      case ('GET', ['stock']):
        final rows = stock.where((s) {
          if (s['deleted'] == true) return false;
          if (q['item'] != null && s['item'] != q['item']) return false;
          if (q['location'] != null) {
            final under = _path(
              locations,
              s['location'] as String,
            ).any((p) => p['id'] == q['location']);
            if (!under) return false;
          }
          return true;
        }).toList();
        return _json({
          'total': rows.length,
          'limit': 100,
          'offset': 0,
          'rows': rows
              .map((s) => stockJson(s['id'] as String)..remove('values'))
              .toList(),
        });
      case ('GET', ['stock', final id]):
        return _json(stockJson(id));
      case ('GET', ['codes', final code]):
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
      case ('GET', ['unit-groups']):
        return _json([group]);
      case ('GET', ['unit-groups', _]):
        return _json({
          ...group,
          'units': [millivolt, volt],
        });
      case ('GET', ['units']):
        return _json([millivolt, volt]);
      case ('GET', ['attributes']):
        return _json([voltage]);
      case ('GET', ['attributes', _]):
        return _json(voltage);
      case ('POST', ['items']):
        final item = {
          'id': _id('i'),
          'code': _code('1D'),
          'name': body!['name'],
          'class': body['class'],
          'unit_group': null,
          'values': body['values'] ?? {},
        };
        items.add(item);
        return _json(itemJson(item['id'] as String), 201);
      case ('POST', ['stock']):
        final row = {
          'id': _id('s'),
          'code': _code('1E'),
          'item': body!['item'],
          'location': body['location'],
          'quantity': body['quantity'],
        };
        stock.add(row);
        return _json(stockJson(row['id'] as String), 201);
      case ('POST', ['stock', final id, 'move']):
        final s = stock.firstWhere((s) => s['id'] == id);
        final amount = body!['quantity'] as num?;
        if (amount == null || amount == s['quantity']) {
          s['location'] = body['location'];
          return _json(stockJson(id));
        }
        s['quantity'] = (s['quantity'] as num) - amount;
        final row = {
          'id': _id('s'),
          'code': _code('1E'),
          'item': s['item'],
          'location': body['location'],
          'quantity': amount,
        };
        stock.add(row);
        return _json(stockJson(row['id'] as String));
      case ('PATCH', ['items', final id]):
        items.firstWhere((i) => i['id'] == id).addAll(body!);
        return _json(itemJson(id));
      case ('PUT', ['items', final id, 'values', final attribute]):
        (items.firstWhere((i) => i['id'] == id)['values'] as Map)[attribute] =
            body!['value'];
        return _json(itemJson(id));
      case ('DELETE', ['items', final id, 'values', final attribute]):
        (items.firstWhere((i) => i['id'] == id)['values'] as Map).remove(
          attribute,
        );
        return _json(itemJson(id));
      case ('GET', ['locations', final id, 'deletion']):
        final below = locations
            .where(
              (l) =>
                  _path(locations, l['id'] as String).any((p) => p['id'] == id),
            )
            .toList();
        final ids = below.map((l) => l['id']).toSet();
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
                ...stockJson(s['id'] as String),
                'item': {
                  'id': s['item'],
                  'code': '1B00',
                  'name': 'Cordless drill',
                },
              },
          ],
        });
      case ('DELETE', ['locations', final id]):
        final ids = locations
            .where(
              (l) =>
                  _path(locations, l['id'] as String).any((p) => p['id'] == id),
            )
            .map((l) => l['id'])
            .toSet();
        final used = stock.any((s) => ids.contains(s['location']));
        if (used && q['force'] != 'true') return _problem(409, 'In use');
        for (final l in locations.where((l) => ids.contains(l['id']))) {
          l['deleted'] = true;
        }
        for (final s in stock.where((s) => ids.contains(s['location']))) {
          s['deleted'] = true;
        }
        return http.Response('', 204, headers: _headers);
      case ('POST', ['locations', final id, 'restore']):
        final l = locations.firstWhere((l) => l['id'] == id);
        final parent = locations
            .where((p) => p['id'] == l['parent'])
            .firstOrNull;
        if (parent?['deleted'] == true) {
          if (body?['with_parents'] == true) {
            parent!['deleted'] = false;
          } else if (body?.containsKey('parent') == true) {
            l['parent'] = body!['parent'];
          } else {
            return _json({
              'type': '/problems/deleted',
              'title': 'Deleted',
              'status': 409,
              'detail':
                  'Location "${l['name']}" is in "${parent!['name']}", which is deleted',
              'hint': 'Restore it together with what it is in ("with_parents": true), or somewhere else ("parent": …).',
            }, 409);
          }
        }
        l['deleted'] = false;
        return _json(locationJson(id));
      case ('GET', [final kind, final id, 'history']):
        final rows = history['$kind/$id'] ?? const [];
        return _json({
          'total': rows.length,
          'limit': 100,
          'offset': 0,
          'rows': rows,
        });
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
