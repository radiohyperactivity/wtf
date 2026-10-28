import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wtf/api/client.dart';
import 'package:wtf/api/models.dart';

final server = Uri.parse('http://wtf.test:8080');

const account = {
  'id': 'a1',
  'email': 'bbj@bbj.io',
  'has_password': true,
  'data_privilege': 'read_write',
  'model_privilege': 'read_only',
  'account_privilege': 'none',
  'history_privilege': 'read_only',
  'deleted': false,
};

http.Response json(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {
    'content-type': 'application/json',
    'api-revision': '1',
    ...headers,
  },
);

void main() {
  test('login keeps the session cookie and sends it back', () async {
    final seen = <http.Request>[];
    String? stored;
    final client = ApiClient(
      server,
      manageCookie: true,
      onSession: (s) => stored = s,
      httpClient: MockClient((req) async {
        seen.add(req);
        if (req.url.path == '/api/v1/login') {
          return json(
            {'account': account},
            headers: {
              'set-cookie': 'wtf_session=tok123; Path=/api; Max-Age=2592000; HttpOnly; SameSite=Strict',
            },
          );
        }
        return json(account);
      }),
    );

    final me = await client.login('bbj@bbj.io', 'secret');
    expect(me.email, 'bbj@bbj.io');
    expect(me.dataPrivilege, Privilege.readWrite);
    expect(me.accountPrivilege, Privilege.none);
    expect(stored, 'tok123');
    expect(client.serverRevision, 1);
    expect(seen.first.method, 'POST');
    expect(jsonDecode(seen.first.body), {
      'email': 'bbj@bbj.io',
      'password': 'secret',
    });
    expect(seen.first.headers['Cookie'], isNull);

    await client.me();
    expect(seen.last.url.toString(), 'http://wtf.test:8080/api/v1/me');
    expect(seen.last.headers['Cookie'], 'wtf_session=tok123');
  });

  test('a deleted cookie ends the session', () async {
    String? stored = 'old';
    final client = ApiClient(
      server,
      manageCookie: true,
      session: 'old',
      onSession: (s) => stored = s,
      httpClient: MockClient(
        (req) async => json(
          {
            'type': '/problems/unauthenticated',
            'title': 'Not authenticated',
            'status': 401,
          },
          status: 401,
          headers: {
            'set-cookie':
                'wtf_session=; Path=/api; Max-Age=0; HttpOnly; SameSite=Strict',
          },
        ),
      ),
    );
    await expectLater(
      client.me(),
      throwsA(
        isA<ApiProblem>().having(
          (p) => p.type,
          'type',
          ApiProblem.unauthenticated,
        ),
      ),
    );
    expect(stored, isNull);
    expect(client.session, isNull);
  });

  test('in a browser the cookie is left alone', () async {
    final seen = <http.Request>[];
    final client = ApiClient(
      server,
      httpClient: MockClient((req) async {
        seen.add(req);
        return json(
          {'account': account},
          headers: {'set-cookie': 'wtf_session=tok; Path=/api'},
        );
      }),
    );
    await client.login('a', 'b');
    await client.login('a', 'b');
    expect(client.session, isNull);
    expect(seen.last.headers['Cookie'], isNull);
  });

  test('problems become messages', () async {
    ApiClient answering(http.Response resp) =>
        ApiClient(server, httpClient: MockClient((_) async => resp));
    Future<String> message(http.Response resp) async {
      try {
        await answering(resp).me();
      } on ApiProblem catch (e) {
        return e.message;
      }
      fail('no problem');
    }

    expect(
      await message(
        json({
          'type': '/problems/unauthenticated',
          'title': 'Wrong email or password',
          'status': 401,
        }, status: 401),
      ),
      'Wrong email or password',
    );
    expect(
      await message(
        json({
          'type': '/problems/x',
          'title': 'Too many failed logins',
          'status': 429,
          'detail': 'Wait.',
        }, status: 429),
      ),
      'Too many failed logins: Wait.',
    );
    // A server that only serves a newer version.
    expect(
      await message(
        json(
          {
            'type': ApiProblem.unsupportedVersion,
            'title': 'Unsupported API version',
            'status': 404,
            'supported': [2, 3],
          },
          status: 404,
          headers: {'api-revision': ''},
        ),
      ),
      contains('update the app'),
    );
    expect(
      await message(
        json({
          'type': ApiProblem.unsupportedVersion,
          'title': 'Unsupported API version',
          'status': 404,
          'supported': [0],
        }, status: 404),
      ),
      contains('update the server'),
    );
    // A 404 without API-Revision: a server without /api/v1.
    expect(
      await message(http.Response('404 page not found', 404)),
      contains('update the server'),
    );
    // Not JSON at all.
    expect(
      await message(
        http.Response('bad gateway', 502, reasonPhrase: 'Bad Gateway'),
      ),
      'Bad Gateway: bad gateway',
    );
  });

  test("an unreachable server is a problem too", () async {
    final client = ApiClient(
      server,
      httpClient: MockClient(
        (_) async => throw http.ClientException('refused'),
      ),
    );
    await expectLater(
      client.me(),
      throwsA(
        isA<ApiProblem>().having((p) => p.type, 'type', ApiProblem.unreachable),
      ),
    );
  });

  test('a tree this client changes is fetched again at once', () async {
    final seen = <String>[];
    var version = 1;
    final client = ApiClient(
      server,
      httpClient: MockClient((req) async {
        seen.add('${req.method} ${req.url.path}');
        return switch ((req.method, req.url.path)) {
          ('GET', '/api/v1/locations') => json(
            {
              'version': version,
              'tree': [
                for (var i = 1; i < version; i++)
                  {'id': 'l$i', 'name': 'Box $i', 'children': []},
              ],
            },
            headers: {'etag': '"$version"'},
          ),
          ('POST', '/api/v1/locations') => json({
            'id': 'l${version++}',
            'name': 'Box',
            'parent': null,
          }, status: 201),
          _ => json({'id': 'c1', 'name': 'Tools', 'attributes': []}),
        };
      }),
    );
    final changes = <TreeKind>[];
    client.treeChanges.listen(changes.add);

    expect((await client.tree(TreeKind.locations)).all, isEmpty);
    seen.clear();
    await client.createLocation(name: 'Box');
    expect(seen, ['POST /api/v1/locations', 'GET /api/v1/locations']);
    await pumpEventQueue();
    expect(changes, [TreeKind.locations]);
    expect((await client.tree(TreeKind.locations)).all.single.name, 'Box 1');

    // Assigning an attribute leaves the class tree alone.
    seen.clear();
    await client.unassignAttribute('c1', 'a1');
    expect(seen, ['DELETE /api/v1/classes/c1/attributes/a1']);
    await pumpEventQueue();
    expect(changes, [TreeKind.locations]);
  });

  test('history can only be read', () {
    final a = Account.fromJson({...account, 'history_privilege': 'read_write'});
    expect(a.privileges['history_privilege'], Privilege.readOnly);
    expect(a.privileges['data_privilege'], Privilege.readWrite);
    final me = Me.fromJson({...account, 'history_privilege': 'read_write'});
    expect(me.historyPrivilege, Privilege.readOnly);
  });

  test('server addresses', () {
    expect(
      serverFromInput('wtf.example.com').toString(),
      'https://wtf.example.com',
    );
    expect(
      serverFromInput(' http://localhost:8081/ ').toString(),
      'http://localhost:8081',
    );
    expect(
      serverFromInput('https://wtf.example.com/api/v1').toString(),
      'https://wtf.example.com',
    );
    expect(serverFromInput(''), isNull);
    expect(serverFromInput('ftp://x'), isNull);
  });

  // The client's paths must exist in the API description, like the server's
  // route test.
  test('download file names, as wtfd writes them', () {
    expect(downloadName('attachment; filename=manual.pdf'), 'manual.pdf');
    expect(downloadName('inline; filename="Front view.png"'), 'Front view.png');
    expect(
      downloadName("attachment; filename*=utf-8''R%C3%B8d%20bok.pdf"),
      'Rød bok.pdf',
    );
    expect(downloadName(null), isNull);
  });

  test('the calls are in openapi.yaml', () {
    // The spec's paths and their methods, with parameters as {}.
    final spec = <String, Set<String>>{};
    String? current;
    for (final line in File('../openapi/openapi.yaml').readAsLinesSync()) {
      final path = RegExp(r'^  (/\S*):$').firstMatch(line);
      if (path != null) {
        current = path[1]!.replaceAll(RegExp(r'\{[^}]+\}'), '{}');
        spec[current] = {};
      } else if (line.startsWith('components:')) {
        current = null;
      } else if (current != null) {
        final method = RegExp(r'^    (get|post|put|patch|delete):')
            .firstMatch(line);
        if (method != null) spec[current]!.add(method[1]!.toUpperCase());
      }
    }

    // The client's calls, with interpolations ($id) as {}.
    final source = File('lib/api/client.dart').readAsStringSync();
    final calls = <(String, String)>{
      for (final m in RegExp(
        r"_call\(\s*'([A-Z]+)',\s*'([^']+)'",
      ).allMatches(source))
        (m[1]!, m[2]!.replaceAll(RegExp(r'\$\{[^}]+\}|\$\w+'), '{}')),
      // The trees, through TreeKind.
      for (final kind in TreeKind.values) ('GET', kind.path),
    };
    expect(calls.length, greaterThan(30));
    for (final (method, path) in calls) {
      // History: /{kind}/{id}/history for each kind the client allows; an
      // attachment's owner ({}/attachments/…): each kind with attachments.
      final paths = path == '/{}/{}/history'
          ? ApiClient.historyKinds.map((k) => '/$k/{}/history')
          : path.startsWith('{}/')
          ? [
              for (final k in ['items', 'stock', 'locations', 'classes'])
                '/$k/{}${path.substring(2)}',
            ]
          : [path];
      for (final p in paths) {
        expect(spec[p], contains(method), reason: '$method $p');
      }
    }
  });
}
