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

  final quantity = {'id': 'q-voltage', 'name': 'Voltage', 'datatype': 'float'};
  late final volt = {
    'id': 'u-volt',
    'name': 'volt',
    'symbol': 'V',
    'family': {'id': 'f-voltage', 'name': 'Voltage'},
    'quantity': quantity,
    'base_factor': 1,
    'base_offset': 0,
  };
  late final millivolt = {
    'id': 'u-millivolt',
    'name': 'millivolt',
    'symbol': 'mV',
    'family': {'id': 'f-voltage', 'name': 'Voltage'},
    'quantity': quantity,
    'base_factor': 0.001,
    'base_offset': 0,
  };
  late final family = {
    'id': 'f-voltage',
    'name': 'Voltage',
    'quantity': quantity,
    'units': [millivolt, volt],
  };

  /// Quantities and families (by id) the inventory turned off, and its
  /// choices (null: the default).
  final off = <String>{};
  final choice = <String, bool?>{};

  /// GET /unit-families, by quantity as the server lists them.
  late final families = <Map<String, dynamic>>[family];
  late final voltage = {
    'id': 'a-volt',
    'name': 'Voltage',
    'datatype': 'float',
    'unit': volt,
    'unit_lock': false,
  };

  /// Not in any class; a test gives an item a value of it.
  final manual = {'id': 'a-manual', 'name': 'Manual', 'datatype': 'url'};

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
      'unit': null,
      'unit_lock': false,
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

  /// Whether Drills has Voltage per unit (on stock rows).
  bool voltagePerUnit = false;

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
            'per_unit': voltagePerUnit,
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
    'unit': null,
    'unit_lock': false,
    'photo': (itemAttachments[i['id']] ?? [])
        .where((a) => a['id'] == i['photo'])
        .firstOrNull,
  };

  List<Map<String, dynamic>> _values(Map<String, dynamic> i) => [
    for (final MapEntry(:key, :value) in (i['values'] as Map).entries)
      if (key == 'a-manual')
        {
          'attribute': manual,
          'value': value,
          'display': null,
          'is_default': false,
        }
      else if (key == 'a-volt')
        {
          'attribute': voltage,
          'value': value,
          // As the server scales it within the family: 0.5 is 500 mV.
          'display': (value as num).abs() < 1 && value != 0
              ? {'value': value * 1000, 'unit': millivolt}
              : {'value': value, 'unit': volt},
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
      'attachments': itemAttachments[id] ?? [],
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
        'display': null,
        'uncounted': rows.any((s) => s['quantity'] == null),
      },
      'incomplete': false,
    };
  }

  Map<String, dynamic> get me => {
    'id': 'a1',
    'email': 'anna@example.com',
    'data_privilege': privilege,
    'model_privilege': privilege,
    'account_privilege': 'none',
    'history_privilege': 'read_only',
  };

  /// The bodies of POST /units/import, as sent, with dry_run.
  final List<(String, bool)> unitImports = [];

  /// POST /units/import, as the server does it for files that only add
  /// quantities, or add to Voltage: conflicts when a quantity named Voltage
  /// has another base unit.
  Map<String, dynamic> _importUnits(
    Map<String, dynamic> file,
    String text, {
    required bool dryRun,
  }) {
    final added = {'quantities': [], 'families': [], 'units': []};
    final existing = {'quantities': [], 'families': [], 'units': []};
    final conflicts = [];
    final newFamilies = <Map<String, dynamic>>[];
    for (final q in (file['quantities'] as List).cast<Map<String, dynamic>>()) {
      final name = q['name'] as String;
      if (name == 'Voltage') {
        if ((q['base_unit'] as Map)['symbol'] != 'V') {
          conflicts.add({
            'where': 'Voltage',
            'message': 'There is a quantity Voltage already, with base unit V',
          });
          continue;
        }
        existing['quantities']!.add({'name': name});
      } else {
        added['quantities']!.add({'name': name});
      }
      final quantity = {
        'id': 'f-new${newFamilies.length}',
        'name': name,
        'datatype': 'float',
      };
      for (final f
          in ((q['families'] as List?) ?? []).cast<Map<String, dynamic>>()) {
        final family = f['name'] as String;
        final units = [];
        for (final u
            in ((f['units'] as List?) ?? []).cast<Map<String, dynamic>>()) {
          final known =
              family == 'Voltage' &&
              (u['symbol'] == 'V' || u['symbol'] == 'mV');
          (known ? existing : added)['units']!.add({
            'quantity': name,
            'family': family,
            'symbol': u['symbol'],
            'name': u['name'],
          });
          units.add({
            'id': 'u-new${units.length}',
            'name': u['name'],
            'symbol': u['symbol'],
            'family': {'id': 'f-new${newFamilies.length}', 'name': family},
            'quantity': quantity,
            'base_factor': u['factor'],
            'base_offset': 0,
          });
        }
        if (family == 'Voltage') {
          existing['families']!.add({'quantity': name, 'name': family});
        } else {
          added['families']!.add({'quantity': name, 'name': family});
          newFamilies.add({
            'id': 'f-new${newFamilies.length}',
            'name': family,
            'quantity': quantity,
            'units': units,
          });
        }
      }
    }
    unitImports.add((text, dryRun));
    final applied = !dryRun && conflicts.isEmpty;
    if (applied) families.addAll(newFamilies);
    return {
      'applied': applied,
      'dry_run': dryRun,
      for (final k in added.keys)
        k: {'added': added[k], 'existing': existing[k]},
      'conflicts': conflicts,
    };
  }

  /// The attachments of items, by item id.
  final Map<String, List<Map<String, dynamic>>> itemAttachments = {};

  /// The where filters of the last GET /items, as sent.
  String? lastWhere;

  /// A number filter on an item's own value, as the server compares them.
  bool _matches(Map<String, dynamic> item, Map<String, dynamic> f) {
    final v = (item['values'] as Map)[f['attribute']];
    final x = f['value'];
    if (v is! num) return false;
    return switch (f['op']) {
      '=' => v == x,
      '>' => v > (x as num),
      '>=' => v >= (x as num),
      '<' => v < (x as num),
      '<=' => v <= (x as num),
      'between' => v >= (x as List)[0] && v <= x[1],
      _ => false,
    };
  }

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
    final multipart =
        req.headers['content-type']?.startsWith('multipart/') ?? false;
    final body = req.body.isEmpty || multipart
        ? null
        : jsonDecode(req.body) as Map<String, dynamic>;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();

    if (path == '/login') {
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
      // The history of a list: history['locations'] and so on.
      case ('GET', [final kind, 'history']):
        final rows = history[kind] ?? const [];
        return _json({
          'total': rows.length,
          'limit': 100,
          'offset': 0,
          'rows': rows,
        });
      case ('GET', ['classes']):
        return _json({'version': 1, 'tree': _tree(classes, null)});
      case ('GET', ['locations']):
        return _json({'version': 1, 'tree': _tree(locations, null)});
      case ('GET', ['classes', final id]):
        return _json(classJson(id));
      case ('GET', ['locations', final id]):
        return _json(locationJson(id));
      case ('GET', ['items']):
        lastWhere = q['where'];
        final where = q['where'] == null
            ? const <Map<String, dynamic>>[]
            : (jsonDecode(q['where']!) as List).cast<Map<String, dynamic>>();
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
              (q['class'] == null || i['class'] == q['class']) &&
              where.every((f) => _matches(i, f));
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
      case ('POST', ['units', 'import']):
        return _json(
          _importUnits(body!, req.body, dryRun: q['dry_run'] == 'true'),
        );
      case ('GET', ['unit-families']):
        return _json([
          for (final f in families)
            {
              ...f,
              'available':
                  !off.contains(f['id']) &&
                  !off.contains((f['quantity'] as Map)['id']),
              'choice': choice[f['id']],
            },
        ]);
      case ('GET', ['quantities']):
        return _json(
          {
            for (final f in families)
              (f['quantity'] as Map)['id']: {
                ...(f['quantity'] as Map<String, dynamic>),
                'available': !off.contains((f['quantity'] as Map)['id']),
                'choice': choice[(f['quantity'] as Map)['id']],
              },
          }.values.toList(),
        );
      case ('PATCH', ['quantities' || 'unit-families', final id]):
        final available = body!['available'] as bool?;
        // Everything here is on as standard; a choice that is the standard
        // isn't kept, as on the server.
        choice[id] = available == true ? null : available;
        if (available == false) {
          off.add(id);
        } else {
          off.remove(id);
        }
        return _json({'id': id});
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
          'unit': null,
          'unit_lock': false,
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
      case ('POST', ['items', final id, 'attachments']):
        // The parts of the multipart body, roughly: name="x" ... value.
        String? part(String name) => RegExp(
          'name="$name"(?:; filename="([^"]*)")?\r\n(?:[^\r]*\r\n)*?\r\n([^\r]*)',
        ).firstMatch(req.body)?.let((m) => name == 'file' ? m[1] : m[2]);
        final type =
            RegExp(
              r'content-type: (\S+)',
              caseSensitive: false,
            ).allMatches(req.body).lastOrNull?[1] ??
            '';
        final a = <String, dynamic>{
          'id': _id('att'),
          'title': part('title') ?? part('file'),
          'type': type,
          'size': 3,
          'hash': 'ab',
          'deleted': false,
        };
        (itemAttachments[id] ??= []).add(a);
        final item = items.firstWhere((i) => i['id'] == id);
        if (part('photo') == 'true') item['photo'] = a['id'];
        return _json(a, 201);
      case ('GET', ['items', _, 'attachments', _, 'content']):
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {
            ..._headers,
            'content-type': 'application/pdf',
            'content-disposition': 'attachment; filename=Manual.pdf',
          },
        );
      case ('GET', ['items', final id, 'attachments', final attachment]):
        return _json(
          itemAttachments[id]!.firstWhere((a) => a['id'] == attachment),
        );
      case (
        'POST',
        ['items', final id, 'attachments', final attachment, 'restore'],
      ):
        final a = itemAttachments[id]!.firstWhere((a) => a['id'] == attachment);
        a['deleted'] = false;
        return _json(a);
      case ('DELETE', ['items', final id, 'attachments', final attachment]):
        itemAttachments[id]?.removeWhere((a) => a['id'] == attachment);
        return http.Response('', 204, headers: _headers);
      case ('PATCH', ['items', final id, 'attachments', final attachment]):
        final a = itemAttachments[id]!.firstWhere((a) => a['id'] == attachment);
        a.addAll(body!);
        return _json(a);
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

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
