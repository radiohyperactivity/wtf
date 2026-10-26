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
const tenant = {'id': 't1', 'name': 'Development', 'hostname': 'wtf.test'};

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
            {'account': account, 'tenant': tenant},
            headers: {
              'set-cookie': 'wtf_session=tok123; Path=/api; Max-Age=2592000; HttpOnly; SameSite=Strict',
            },
          );
        }
        return json({...account, 'tenant': tenant});
      }),
    );

    final me = await client.login('bbj@bbj.io', 'secret');
    expect(me.email, 'bbj@bbj.io');
    expect(me.dataPrivilege, Privilege.readWrite);
    expect(me.accountPrivilege, Privilege.none);
    expect(me.tenant.name, 'Development');
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
          {'account': account, 'tenant': tenant},
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
  test('the paths are in openapi.yaml', () {
    final spec = File('../openapi/openapi.yaml').readAsStringSync();
    final source = File('lib/api/client.dart').readAsStringSync();
    final paths = RegExp(r"_send\('[A-Z]+', '([^']+)'")
        .allMatches(source)
        .map((m) => m[1]!)
        .toSet();
    expect(paths, isNotEmpty);
    for (final path in paths) {
      expect(spec, contains('\n  $path:\n'), reason: path);
    }
  });
}
