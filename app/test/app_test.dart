import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wtf/app.dart';
import 'package:wtf/session.dart';

const account = {
  'id': 'a1',
  'email': 'bbj@bbj.io',
  'data_privilege': 'read_write',
  'model_privilege': 'read_write',
  'account_privilege': 'none',
  'history_privilege': 'read_only',
};
const tenant = {'id': 't1', 'name': 'Development', 'hostname': 'wtf.test'};
const headers = {'content-type': 'application/json', 'api-revision': '1'};

/// A pretend wtfd with one account, bbj@bbj.io with password "secret".
MockClient fakeServer() => MockClient((req) async {
  final cookie = req.headers['Cookie'];
  switch (req.url.path) {
    case '/api/v1/login':
      final body = jsonDecode(req.body);
      if (body['email'] != 'bbj@bbj.io' || body['password'] != 'secret') {
        return http.Response(
          jsonEncode({
            'type': '/problems/unauthenticated',
            'title': 'Wrong email or password',
            'status': 401,
          }),
          401,
          headers: headers,
        );
      }
      return http.Response(
        jsonEncode({'account': account, 'tenant': tenant}),
        200,
        headers: {
          ...headers,
          'set-cookie': 'wtf_session=tok; Path=/api; Max-Age=2592000; HttpOnly',
        },
      );
    case '/api/v1/me' when cookie == 'wtf_session=tok':
      return http.Response(
        jsonEncode({...account, 'tenant': tenant}),
        200,
        headers: headers,
      );
    case '/api/v1/logout':
      return http.Response(
        '',
        204,
        headers: {
          ...headers,
          'set-cookie': 'wtf_session=; Path=/api; Max-Age=0',
        },
      );
  }
  return http.Response(
    jsonEncode({
      'type': '/problems/unauthenticated',
      'title': 'Not authenticated',
      'status': 401,
    }),
    401,
    headers: headers,
  );
});

Future<void> setWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('log in, see the account, log out', (tester) async {
    await setWidth(tester, 400);
    final storage = MemoryStorage();
    final session = Session(storage: storage, httpClient: fakeServer());
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();

    // The native app asks for the server too.
    expect(find.text('Log in'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Server'), findsOneWidget);

    // Nothing filled in.
    await tester.tap(find.text('Log in'));
    await tester.pump();
    expect(find.text('Enter the server address'), findsOneWidget);
    expect(find.text('Enter your email'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server'),
      'http://wtf.test:8080',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'bbj@bbj.io',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'wrong',
    );
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong email or password'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'secret',
    );
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    // The search screen, with the bottom bar of a narrow screen.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('The search comes here.'), findsOneWidget);
    expect(storage.server, 'http://wtf.test:8080');
    expect(storage.token, 'tok');

    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    expect(find.text('bbj@bbj.io'), findsOneWidget);
    expect(find.text('Development'), findsOneWidget);

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(storage.token, isNull);
    // The server is remembered.
    expect(find.text('http://wtf.test:8080'), findsOneWidget);
  });

  testWidgets('a stored session continues, with a rail on wide screens', (
    tester,
  ) async {
    await setWidth(tester, 1000);
    final session = Session(
      storage: MemoryStorage(server: 'http://wtf.test:8080', token: 'tok'),
      httpClient: fakeServer(),
    );
    await session.restore();
    expect(session.me?.email, 'bbj@bbj.io');
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('The search comes here.'), findsOneWidget);
  });

  testWidgets('the web app uses its own address and no server field', (
    tester,
  ) async {
    await setWidth(tester, 400);
    final storage = MemoryStorage();
    final session = Session(
      storage: storage,
      webOrigin: Uri.parse('http://wtf.test:8080'),
      httpClient: fakeServer(),
    );
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Server'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    // The browser keeps the cookie, never the app.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'bbj@bbj.io',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'secret',
    );
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('The search comes here.'), findsOneWidget);
    expect(storage.token, isNull);
    expect(storage.server, isNull);
  });
}
