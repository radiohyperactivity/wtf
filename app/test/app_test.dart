import 'dart:convert';
import 'dart:io' show HandshakeException;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart' hide FileImage;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wtf/app.dart';
import 'package:wtf/camera.dart' show cameraPoll;
import 'package:wtf/screens/model_import.dart';
import 'package:wtf/screens/search_screen.dart';
import 'package:wtf/session.dart';
import 'package:wtf/theme.dart';
import 'package:wtf/widgets/common.dart' show SwitchTile;
import 'package:wtf/widgets/files.dart';
import 'package:wtf/widgets/link.dart';

import 'fake_server.dart';

final server = Uri.parse('http://wtf.test:8080');

void setSize(WidgetTester tester, double width, [double height = 1400]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The app, logged in to [fake].
Future<void> startApp(WidgetTester tester, FakeServer fake) async {
  final session = Session(storage: MemoryStorage(), httpClient: fake.client);
  await session.login('anna@example.com', 'secret', server: server);
  await tester.pumpWidget(WtfApp(session: session));
  await tester.pumpAndSettle();
}

/// Opens the app's screen at [path], on top of the one shown.
Future<void> open(WidgetTester tester, String path) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).push(path);
  await tester.pumpAndSettle();
}

/// Types into the search field and waits for the results.
/// Searches from the Items form, going back to it from results first.
Future<void> search(WidgetTester tester, String text) async {
  if (find.byType(FoundItemsScreen).evaluate().isNotEmpty) {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byType(TextField).first, text);
  await tester.tap(find.widgetWithText(FilledButton, 'Search'));
  await tester.pumpAndSettle();
}

/// Opens the item [name] found by searching for it.
Future<void> openItem(WidgetTester tester, String name) async {
  await search(tester, name);
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Finder field(String label) => find.widgetWithText(TextFormField, label);

/// Opens the menu of the screen's app bar and picks [entry].
Future<void> menu(WidgetTester tester, String entry) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(PopupMenuButton<String>),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(entry));
  await tester.pumpAndSettle();
}

/// The topmost button with [text]: a confirmation's, over a dialog's.
Finder button(String text) => find.widgetWithText(FilledButton, text).last;

/// Opens the Account screen's tab [name], scrolling the tabs to it where
/// they don't all fit.
Future<void> openTab(WidgetTester tester, String name) async {
  await tester.ensureVisible(find.widgetWithText(Tab, name));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, name));
  await tester.pumpAndSettle();
}

void clearMessages(WidgetTester tester) => tester
    .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
    .clearSnackBars();

void main() {
  testWidgets('not reaching the server says why, at the login', (tester) async {
    setSize(tester, 400, 800);
    // An HTTPS request to a server that speaks plain HTTP.
    final session = Session(
      storage: MemoryStorage(),
      httpClient: MockClient(
        (req) async => throw const HandshakeException('WRONG_VERSION_NUMBER'),
      ),
    );
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(find.textContaining('unless you write http://'), findsOneWidget);
    await tester.enterText(field('Server'), '192.168.1.10:8080');
    await tester.enterText(field('Email'), 'anna@example.com');
    await tester.enterText(field('Password'), 'secret');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('write the address with http://'),
      findsOneWidget,
    );
  });

  testWidgets('log in for a while, see the sessions, log out', (tester) async {
    setSize(tester, 400, 1200);
    final fake = FakeServer();
    final storage = MemoryStorage();
    final session = Session(storage: storage, httpClient: fake.client);
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();

    // The native app asks for the server too.
    expect(field('Server'), findsOneWidget);
    await tester.tap(find.text('Log in'));
    await tester.pump();
    expect(find.text('Enter the server address'), findsOneWidget);

    await tester.enterText(field('Server'), 'http://wtf.test:8080');
    await tester.enterText(field('Email'), 'anna@example.com');
    await tester.enterText(field('Password'), 'secret');
    // How long the session may sit unused: 30 days unless chosen.
    expect(find.text('30 days'), findsOneWidget);
    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A week').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(fake.login!['max_idle'], 7 * 24 * 3600);
    expect(fake.login!['client'], startsWith('WtF on '));

    // The search screen, with the bottom bar of a narrow screen.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.textContaining('Search items by name'), findsOneWidget);
    expect(storage.server, 'http://wtf.test:8080');
    expect(storage.token, 'tok');

    // Account: the account; its sessions, this one marked, on a tab of
    // their own.
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('anna@example.com'), findsOneWidget);
    await openTab(tester, 'Sessions');
    expect(find.text('WtF on Windows (this one)'), findsOneWidget);
    expect(find.text('WtF on Android'), findsOneWidget);
    expect(find.textContaining('from 10.0.0.7'), findsOneWidget);
    expect(find.textContaining('until logged out'), findsOneWidget);
    await tester.tap(find.text('Log out everywhere else'));
    await tester.pumpAndSettle();
    await tester.tap(button('Log out'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'POST /api/v1/me/sessions/logout-others');
    expect(find.text('Logged out 1 other session.'), findsOneWidget);
    expect(find.text('WtF on Android'), findsNothing);

    // The versions, on the last tab: this test's app is built without the
    // scripts' stamp.
    await openTab(tester, 'About');
    expect(find.text('Server 0.1.0'), findsOneWidget);
    expect(find.text('App (a development build)'), findsOneWidget);
    expect(
      find.textContaining('commit 70ef34d of 18 Nov 2026'),
      findsOneWidget,
    );

    // A new password: the other devices are logged out, unless unticked.
    clearMessages(tester);
    await tester.pumpAndSettle();
    await openTab(tester, 'Account');
    await tester.ensureVisible(find.text('Change password'));
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Current password'), 'secret');
    await tester.enterText(field('New password'), 'new secret');
    await tester.enterText(field('New password again'), 'new secret');
    expect(find.text('Log out my other devices'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Change'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PUT /api/v1/me/password '
      '{"current":"secret","new":"new secret","end_other_sessions":true}',
    );

    clearMessages(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Log out'));
    await tester.tap(find.widgetWithText(FilledButton, 'Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('Admin holds classes and accounts, and model files', (
    tester,
  ) async {
    setSize(tester, 400, 800);
    await startApp(tester, FakeServer());
    // Four destinations; classes aren't one.
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final entry in ['Classes', 'Import', 'Export', 'Accounts']) {
      expect(find.widgetWithText(ListTile, entry), findsOneWidget);
    }
    // Attributes are in their class, and units are labels.
    expect(find.widgetWithText(ListTile, 'Attributes'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Units'), findsNothing);
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('bob@example.com'), findsOneWidget);
    // Still under Admin.
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
  });

  testWidgets('a new password for an account: log it out everywhere?', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await open(tester, '/accounts/a2');
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'New password'),
      'long enough',
    );
    // Asked, and not suggested for a new password.
    final logOut = find.widgetWithText(
      CheckboxListTile,
      'Log the user out everywhere',
    );
    expect(tester.widget<CheckboxListTile>(logOut).value, isFalse);
    await tester.tap(logOut);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/accounts/a2 {"password":"long enough","end_sessions":true}',
    );

    // Suggested when the password is removed.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(logOut).value, isTrue);

    // Your own password is changed under Account.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await open(tester, '/accounts/a1');
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.text('Your own password is changed under Account.'),
      findsOneWidget,
    );
    expect(find.text('Set'), findsNothing);
  });

  testWidgets('a dropdown takes letters and arrows, as a select box', (
    tester,
  ) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer());
    await open(tester, '/classes/c-drills');
    await tester.tap(find.widgetWithText(TextButton, 'Add').first);
    await tester.pumpAndSettle();
    expect(find.text('New attribute of Drills'), findsOneWidget);
    await tester.enterText(field('Name'), 'Clock');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    String type() => tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .initialValue!;

    Future<void> press(List<LogicalKeyboardKey> keys) async {
      for (final k in keys) {
        await tester.sendKeyEvent(k);
      }
      await tester.pumpAndSettle();
    }

    // By the names shown: "integer" is an integer, typed with I.
    await press([LogicalKeyboardKey.keyI]);
    expect(type(), 'integer');
    // The arrows pick the next and previous type, and stay in the field.
    await press([LogicalKeyboardKey.arrowDown]);
    expect(type(), 'decimal');
    await press([LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp]);
    expect(type(), 'text');
    expect(find.text('Clock'), findsOneWidget); // no menu, still the dialog
    await press([LogicalKeyboardKey.keyL]);
    expect(type(), 'url');
    // Letters typed together are one name; an arrow starts afresh.
    await press([LogicalKeyboardKey.keyF]);
    expect(type(), 'url');
    await press([LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyF]);
    expect(type(), 'attachment');
    // A number has a unit, a file its types, and neither a default.
    expect(field('File types'), findsOneWidget);
    expect(field('Default'), findsNothing);
    await press([LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.keyN]);
    expect(type(), 'decimal');
    expect(field('Unit'), findsOneWidget);
    expect(field('Default'), findsOneWidget);
  });

  testWidgets('a picker field opens on a letter, searching for it', (
    tester,
  ) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer());
    // From the search field to Class, then a letter. Tests run as on
    // Android, where the search field doesn't take the focus by itself.
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pumpAndSettle();
    expect(find.text('Only items of this class'), findsOneWidget);
    final search = tester.widget<TextField>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
    );
    expect(search.controller!.text, 'd');
    expect(
      search.controller!.selection,
      const TextSelection.collapsed(offset: 1),
    );
    expect(find.text('Tools/Drills'), findsOneWidget);
    // Enter takes the first match.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Only items of this class'), findsNothing);
    expect(find.text('Tools/Drills'), findsOneWidget); // in the class field
    // The down arrow opens it too, with nothing typed.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Only items of this class'), findsOneWidget);
  });

  testWidgets('import a model file: a preview first, then the model', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    const file =
        '{"format": "wtf-model", "version": 2, '
        '"meta": {"name": "Microcontrollers"}, "classes": [{"name": "MCU"}]}';
    pickModelFile = () async => (name: 'mcu.json', text: file);
    addTearDown(() => pickModelFile = () async => null);
    await startApp(tester, fake);
    // Importing is under Admin, and nowhere else; so are the classes.
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Classes'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.upload_file), findsNothing);
    // The class tree belongs to Admin, and Back goes there.
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      2,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // A dry run first: what it adds, and where.
    await tester.tap(find.widgetWithText(ListTile, 'Import'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'POST /api/v1/model/import?dry_run=true $file');
    expect(find.text('Import Microcontrollers (mcu.json)'), findsOneWidget);
    expect(
      find.text('Its classes go at the top of the class tree.'),
      findsOneWidget,
    );
    expect(find.textContaining('2 attributes'), findsOneWidget);
    expect(
      find.text(
        '1 attribute in the file is there already, and is used as it is.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'POST /api/v1/model/import $file');
    expect(find.text('Imported 1 class and 2 attributes.'), findsOneWidget);

    // Below a class: Change… chooses it, and the dry run is done again.
    await tester.tap(find.widgetWithText(ListTile, 'Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change…'));
    await tester.pumpAndSettle();
    expect(find.text('Import the classes below'), findsOneWidget);
    expect(find.text('(top level)'), findsOneWidget);
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'POST /api/v1/model/import?parent=c-drills&dry_run=true $file',
    );
    expect(find.text('Its classes go below Tools/Drills.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'POST /api/v1/model/import?parent=c-drills $file',
    );
  });

  testWidgets('export a class as a model file, from Admin or its menu', (
    tester,
  ) async {
    setSize(tester, 1000);
    final saved = <(String, String)>[];
    saveDownloadedFile = (name, bytes) async =>
        saved.add((name, utf8.decode(bytes)));
    addTearDown(() => saveDownloadedFile = (name, bytes) async {});
    await startApp(tester, FakeServer());
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export which class?'), findsOneWidget);
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    // Named after the class, indented, its keys in the format's order.
    expect(saved.single.$1, 'Drills.json');
    expect(
      saved.single.$2,
      startsWith('{\n  "format": "wtf-model",\n  "version": 2,\n  "meta": {'),
    );
    expect(saved.single.$2, endsWith('}\n'));

    await open(tester, '/classes/c-drills');
    await menu(tester, 'Export as a model file…');
    expect(saved.map((s) => s.$1), ['Drills.json', 'Drills.json']);
  });

  testWidgets('the item photo: beside the details, or above the stock', (
    tester,
  ) async {
    final fake = FakeServer();
    fake.items.first['photo'] = 'hash-front';

    // Wide: small photos in the results table, the photo right of the
    // details, which include the values without a header of their own.
    setSize(tester, 1200);
    await startApp(tester, fake);
    await search(tester, 'drill');
    expect(find.byType(FileImage), findsOneWidget);
    // A small photo is a thumbnail: 48 wide, the box twice that.
    final small = tester.widget<Image>(
      find.descendant(of: find.byType(FileImage), matching: find.byType(Image)),
    );
    expect(
      ((small.image as ResizeImage).imageProvider as ApiImage).url,
      endsWith('?v=hash-front&size=96'),
    );
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    expect(find.text('Values'), findsNothing);
    final photo = tester.getRect(find.byType(ObjectPhoto));
    final code = tester.getRect(find.text('Code'));
    expect(photo.left, greaterThan(code.right));
    expect(photo.top, lessThan(tester.getRect(find.text('Voltage')).bottom));

    // Images are decoded for the size they're shown at: the photo at most
    // as wide as its box, here 240 by 320, and downloaded as a thumbnail
    // that fits in it. Its address changes with its content.
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(ObjectPhoto),
        matching: find.byType(Image),
      ),
    );
    final big = image.image as ResizeImage;
    expect((big.width, big.height), (240, 320));
    expect(
      (big.imageProvider as ApiImage).url,
      'http://wtf.test:8080/api/v1/items/i-drill/photo?v=hash-front&size=320',
    );

    // Narrow: the photo as wide as the screen, under the values and above
    // the stock.
    setSize(tester, 400);
    await tester.pumpAndSettle();
    final narrow = tester.getRect(find.byType(ObjectPhoto));
    expect(
      narrow.top,
      greaterThan(tester.getRect(find.text('Voltage')).bottom),
    );
    // The section's heading, after the field saying how it is counted.
    expect(
      narrow.bottom,
      lessThan(tester.getRect(find.text('Stock').last).top),
    );
    expect(narrow.width, 400 - 32);
  });

  testWidgets('a photo: choose one, then remove it', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    pickUploadFile = ({bool image = false}) async =>
        image ? ('front.png', () async => [1, 2, 3]) : null;
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');
    expect(find.byType(ObjectPhoto), findsNothing);

    await menu(tester, 'Photo…');
    await tester.tap(find.text('Choose a photo'));
    await tester.pumpAndSettle();
    final upload = fake.changes.last;
    expect(upload, startsWith('PUT /api/v1/items/i-drill/photo'));
    expect(upload, contains('filename="front.png"'));
    expect(upload.toLowerCase(), contains('content-type: image/png'));
    expect(find.byType(ObjectPhoto), findsOneWidget);

    clearMessages(tester);
    await tester.pumpAndSettle();
    await menu(tester, 'Photo…');
    expect(find.text('Replaces the current photo'), findsOneWidget);
    expect(find.text('Choose a photo'), findsOneWidget);
    await tester.tap(find.text('Remove the photo'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'PATCH /api/v1/items/i-drill {"photo":null}');
    expect(find.byType(ObjectPhoto), findsNothing);
  });

  testWidgets('a location photo: by an admin, in the tree, for stock rows', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    pickUploadFile = ({bool image = false}) async =>
        image ? ('shelf.png', () async => [1, 2, 3]) : null;
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    await startApp(tester, fake);
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/locations/1A01');
    await tester.pumpAndSettle();
    expect(find.byType(ObjectPhoto), findsNothing);

    await menu(tester, 'Photo…');
    await tester.tap(find.text('Choose a photo'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      startsWith('PUT /api/v1/locations/l-shelf1/photo'),
    );
    expect(find.byType(ObjectPhoto), findsOneWidget);

    // A stock row without a photo of its own shows its location's, and the
    // tree shows it too.
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/items/1B00');
    await tester.pumpAndSettle();
    final thumb = find.descendant(
      of: find.widgetWithText(ListTile, 'Garage/Shelf 1'),
      matching: find.byType(FileImage),
    );
    expect(tester.widget<FileImage>(thumb).file.owner, '/locations/l-shelf1');
    fake.stock.first['photo'] = 'hash-own';
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    router.go('/locations');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<FileImage>(find.byType(FileImage))
          .map((i) => i.file.owner),
      contains('/locations/l-shelf1'),
    );
    router.go('/items/1B00');
    await tester.pumpAndSettle();
    expect(tester.widget<FileImage>(thumb).file.owner, '/stock/s-1');

    // Removing it is a patch of the photo alone.
    clearMessages(tester);
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/locations/1A01');
    await tester.pumpAndSettle();
    await menu(tester, 'Photo…');
    await tester.tap(find.text('Remove the photo'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/locations/l-shelf1 {"photo":null}',
    );
    expect(find.byType(ObjectPhoto), findsNothing);
  });

  testWidgets('a file attribute: upload, open, save, remove', (tester) async {
    setSize(tester, 700);
    final fake = FakeServer();
    pickUploadFile = ({bool image = false}) async =>
        ('drill.pdf', () async => [1, 2, 3]);
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    final saved = <(String, List<int>)>[];
    saveDownloadedFile = (name, bytes) async => saved.add((name, bytes));
    addTearDown(() => saveDownloadedFile = (name, bytes) async {});
    final opened = <(String, String)>[];
    openDownloadedFile = (f, name, type, bytes) async {
      opened.add((name, type));
      return true;
    };
    addTearDown(
      () => openDownloadedFile = (f, name, type, bytes) async => false,
    );
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');

    // Under Files, with the types it takes; a tap uploads one.
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('No file. Takes application/pdf'), findsOneWidget);
    await tester.tap(find.text('Datasheet'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      startsWith('PUT /api/v1/items/i-drill/files/Datasheet'),
    );
    expect(fake.changes.last, contains('filename="drill.pdf"'));
    expect(find.text('Tap to open'), findsOneWidget);

    // A tap opens it, named as the server names it, with its type.
    clearMessages(tester);
    await tester.tap(find.text('Datasheet'));
    await tester.pumpAndSettle();
    expect(opened, [('Datasheet.pdf', 'application/pdf')]);

    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    expect(saved.single.$1, 'Datasheet.pdf');
    expect(saved.single.$2, [1, 2, 3]);

    // Removing it is a change of its value.
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove…'));
    await tester.pumpAndSettle();
    await tester.tap(button('Remove'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/items/i-drill {"values":{"Datasheet":null}}',
    );
    expect(find.text('No file. Takes application/pdf'), findsOneWidget);
  });

  testWidgets('photos and files on the edit forms, and one not uploaded', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    (fake.items.first['values'] as Map)['Datasheet'] = 'hash-old';
    fake.locations.firstWhere((l) => l['id'] == 'l-shelf1')['stock_photos'] =
        true;
    var broken = false;
    pickUploadFile = ({bool image = false}) async => (
      'front.png',
      () async => broken ? throw const FetchError('Gone.') : [1, 2, 3],
    );
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    // The file it has can be removed, and a photo chosen; both are done
    // when saved, the removal in the change itself.
    expect(find.text('Has a file'), findsOneWidget);
    expect(find.text('No photo'), findsOneWidget);
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Removed when saved'), findsOneWidget);
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    expect(find.text('Keep the current file'), findsOneWidget);
    await tester.tap(find.text('Keep the current file'));
    await tester.pumpAndSettle();
    expect(find.text('Has a file'), findsOneWidget);
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    expect(find.text('front.png, sent when saved'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes[fake.changes.length - 2],
      'PATCH /api/v1/items/i-drill {"values":{"Datasheet":null}}',
    );
    expect(fake.changes.last, startsWith('PUT /api/v1/items/i-drill/photo'));
    expect(find.byType(ObjectPhoto), findsOneWidget);

    // A stock row's photo that can't be sent: the rest is saved, and the
    // app says what wasn't.
    clearMessages(tester);
    broken = true;
    final before = fake.changes.length;
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .push('/stock/1C00/edit');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Amount'), '3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.changes.skip(before), ['PATCH /api/v1/stock/s-1 {"amount":3}']);
    expect(
      find.text(
        'Saved, but this file was not uploaded: Photo (Gone.). '
        'Upload it on its screen.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('stock photos only where the location takes them', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));

    // Shelf 1 takes none: the stock row's menu has no Photo, nor its form.
    router.go('/stock/1C00');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Photo…'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Photo'), findsNothing);

    // An admin turns them on for the shelf, on its form.
    router.go('/locations/1A01');
    await tester.pumpAndSettle();
    await menu(tester, 'Edit');
    expect(
      tester
          .widget<SwitchTile>(
            find.widgetWithText(SwitchTile, 'Photos of stock'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('Photos of stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/locations/l-shelf1 {"stock_photos":true}',
    );

    // Now the stock row has a Photo.
    router.go('/stock/1C00');
    await tester.pumpAndSettle();
    await menu(tester, 'Photo…');
    expect(find.text('Choose a photo'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    // A new location below it starts as it does.
    router.go('/locations/new?parent=l-shelf1');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchTile>(
            find.widgetWithText(SwitchTile, 'Photos of stock'),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('a file and a photo fetched from a URL, by the app', (
    tester,
  ) async {
    setSize(tester, 700);
    final fake = FakeServer();
    final fetched = <Uri>[];
    fetchUrlFile = (url) async {
      fetched.add(url);
      if (url.host == 'gone.example') {
        throw const FetchError('gone.example answered 404 Not Found.');
      }
      return (url.pathSegments.last, () async => [1, 2, 3]);
    };
    addTearDown(() => fetchUrlFile = fetchFromUrl);
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');

    // From the file attribute's menu: an address is asked for, and checked.
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch from URL…'));
    await tester.pumpAndSettle();
    expect(find.text('Fetch Datasheet'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, 'drill.pdf');
    await tester.tap(button('Fetch'));
    await tester.pumpAndSettle();
    expect(
      find.text('An address that starts with https:// or http://'),
      findsOneWidget,
    );
    expect(fetched, isEmpty);
    await tester.enterText(
      find.byType(TextFormField).last,
      ' https://shop.example/files/drill.pdf ',
    );
    await tester.tap(button('Fetch'));
    await tester.pumpAndSettle();
    expect(fetched, [Uri.parse('https://shop.example/files/drill.pdf')]);
    expect(
      fake.changes.last,
      startsWith('PUT /api/v1/items/i-drill/files/Datasheet'),
    );
    expect(fake.changes.last, contains('filename="drill.pdf"'));
    expect(find.text('Tap to open'), findsOneWidget);

    // What went wrong is said, and nothing is uploaded.
    clearMessages(tester);
    final before = fake.changes.length;
    await tester.tap(find.byTooltip('Datasheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch from URL…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).last,
      'https://gone.example/a.pdf',
    );
    await tester.tap(button('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('gone.example answered 404 Not Found.'), findsOneWidget);
    expect(fake.changes.length, before);

    // The photo sheet has it too.
    clearMessages(tester);
    await tester.pumpAndSettle();
    await menu(tester, 'Photo…');
    await tester.tap(find.text('From a URL'));
    await tester.pumpAndSettle();
    expect(find.text('Fetch a photo'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).last,
      'http://shop.example/img/drill.jpg',
    );
    await tester.tap(button('Fetch'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, startsWith('PUT /api/v1/items/i-drill/photo'));
    expect(fake.changes.last, contains('filename="drill.jpg"'));
    expect(find.byType(ObjectPhoto), findsOneWidget);
  });

  test('fetching from a URL: its name, and what is refused', () async {
    Future<PickedFile> fetch(
      String url,
      http.Response Function(http.Request request) answer,
    ) => fetchFromUrl(
      Uri.parse(url),
      client: MockClient((request) async => answer(request)),
    );
    Future<String> refusal(Future<PickedFile> fetching) async {
      try {
        await fetching;
      } on FetchError catch (e) {
        return e.message;
      }
      fail('not refused');
    }

    // Named after the address's last part, or as the site names it.
    final pdf = await fetch(
      'https://shop.example/files/drill%20manual.pdf?v=2',
      (_) => http.Response.bytes(
        [1, 2, 3],
        200,
        headers: {'content-type': 'application/pdf'},
      ),
    );
    expect(pdf.$1, 'drill manual.pdf');
    expect(await pdf.$2(), [1, 2, 3]);
    final named = await fetch(
      'https://shop.example/download?id=7',
      (_) => http.Response.bytes(
        [1],
        200,
        headers: {'content-disposition': 'attachment; filename="manual.pdf"'},
      ),
    );
    expect(named.$1, 'manual.pdf');
    final bare = await fetch(
      'https://shop.example/',
      (_) => http.Response.bytes([1], 200),
    );
    expect(bare.$1, 'shop.example');

    // A web page, an error, and a file too large are refused, saying why.
    expect(
      await refusal(
        fetch(
          'https://shop.example/drill',
          (_) => http.Response(
            '<html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      ),
      contains('a web page, not a file'),
    );
    expect(
      await refusal(
        fetch(
          'https://shop.example/gone.pdf',
          (_) => http.Response('', 404, reasonPhrase: 'Not Found'),
        ),
      ),
      startsWith('shop.example answered 404 Not Found'),
    );
    expect(
      await refusal(
        fetchFromUrl(
          Uri.parse('https://shop.example/huge.bin'),
          client: MockClient.streaming(
            (request, body) async => http.StreamedResponse(
              const Stream.empty(),
              200,
              contentLength: fetchLimit + 1,
            ),
          ),
        ),
      ),
      contains('larger than 100 MB'),
    );

    expect(fetchableUrl('ftp://shop.example/a'), isNull);
    expect(fetchableUrl('shop.example/a'), isNull);
    expect(fetchableUrl(' https://shop.example/a '), isNotNull);
  });

  test('file icons: by sub-type, else by major type, else a file', () {
    expect(typeIcon('application/pdf'), Icons.picture_as_pdf_outlined);
    expect(typeIcon('text/csv; charset=utf-8'), Icons.table_chart_outlined);
    expect(
      typeIcon(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ),
      Icons.description_outlined,
    );
    expect(typeIcon('application/zip'), Icons.folder_zip_outlined);
    expect(typeIcon('model/step'), Icons.view_in_ar_outlined);
    expect(typeIcon('audio/flac'), Icons.audio_file_outlined);
    expect(typeIcon('video/webm'), Icons.video_file_outlined);
    expect(typeIcon('text/x-unknown'), Icons.text_snippet_outlined);
    expect(typeIcon('Image/SVG+XML'), Icons.draw_outlined);
    expect(typeIcon('application/x-unknown'), Icons.insert_drive_file_outlined);
  });

  test('opening: what the native apps open, and the file they open', () {
    // Documents too, nothing that runs.
    expect(canOpenType('application/pdf'), isTrue);
    expect(canOpenType('application/zip'), isTrue);
    expect(canOpenType('text/html'), isFalse);
    expect(canOpenType('image/svg+xml'), isFalse);
    expect(canOpenType('application/msword'), isFalse);
    expect(canOpenType('application/x-msdownload'), isFalse);

    // Always the type's extension, and nothing a shell would act on.
    expect(openFileName('Datasheet.pdf', 'application/pdf'), 'Datasheet.pdf');
    expect(openFileName('Photo.jpeg', 'image/jpeg'), 'Photo.jpg');
    expect(openFileName('setup.exe', 'image/png'), 'setup.png');
    expect(
      openFileName('Tools & "parts"/2.pdf', 'application/pdf'),
      'Tools _ _parts__2.pdf',
    );
    expect(openFileName('...', 'text/plain'), 'file.txt');
    expect(openFileName('Kühlschrank', 'text/plain'), 'Kühlschrank.txt');
  });

  testWidgets('the appearance is kept on the device', (tester) async {
    setSize(tester, 400, 800);
    final fake = FakeServer();
    final storage = MemoryStorage(server: 'http://wtf.test:8080', token: 'tok');
    final session = Session(storage: storage, httpClient: fake.client);
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    ThemeMode mode() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;
    expect(mode(), ThemeMode.system);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await openTab(tester, 'Preferences');
    expect(find.text('On this device'), findsOneWidget);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(mode(), ThemeMode.light);
    expect(storage.theme, 'light');

    // System to start with, then the logo's orange, light and dark.
    Color primary() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .colorScheme
        .primary;
    final system = primary();
    await tester.tap(find.text('Orange'));
    await tester.pumpAndSettle();
    expect(storage.colour, 'orange');
    expect(primary(), isNot(system));
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .darkTheme!
          .colorScheme
          .primary,
      appTheme(AppColour.orange, Brightness.dark).colorScheme.primary,
    );

    // The next start.
    final next = Session(storage: storage, httpClient: fake.client);
    await next.restore();
    expect(next.themeMode, ThemeMode.light);
    expect(next.colour, AppColour.orange);
  });

  testWidgets('a stored session continues, with a rail on wide screens', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    final session = Session(
      storage: MemoryStorage(server: 'http://wtf.test:8080', token: 'tok'),
      httpClient: fake.client,
    );
    await session.restore();
    expect(session.me?.email, 'anna@example.com');
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('the web app uses its own address and no server field', (
    tester,
  ) async {
    setSize(tester, 400, 800);
    final fake = FakeServer();
    final storage = MemoryStorage();
    final session = Session(
      storage: storage,
      webOrigin: server,
      httpClient: fake.client,
    );
    await session.restore();
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(field('Server'), findsNothing);
    expect(storage.token, isNull);
  });

  testWidgets('find an item, see where it is, move part of it', (tester) async {
    setSize(tester, 700); // compact results, not the table
    final fake = FakeServer();
    await startApp(tester, fake);

    await search(tester, 'drill');
    expect(find.text('Cordless drill'), findsOneWidget);
    expect(find.text('Garage/Shelf 1'), findsOneWidget); // where its stock is
    expect(find.text('1B00  ·  Tools/Drills'), findsOneWidget);

    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    expect(find.text('18 V'), findsOneWidget);
    expect(find.text('Tools/Drills'), findsOneWidget);
    // A value that follows the class's default says so.
    expect(find.text('Red  (default)'), findsOneWidget);
    // How its stock is counted: its class's rule, here the default.
    expect(find.text('Counted, the amount optional · pieces'), findsOneWidget);

    await tester.tap(find.text('Garage/Shelf 1'));
    await tester.pumpAndSettle();
    expect(find.text('Amount'), findsOneWidget);

    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a location'));
    await tester.pumpAndSettle();
    // The current place isn't offered; the container is, but can't be chosen.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Garage/Shelf 1'),
      ),
      findsNothing,
    );
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Garage/')).enabled,
      isFalse,
    );
    await tester.tap(find.text('Garage/Shelf 2'));
    await tester.pumpAndSettle();
    // Pieces are whole.
    await tester.enterText(field('Amount'), '1.5');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();
    expect(find.text('"1.5" is not an integer'), findsOneWidget);
    await tester.enterText(field('Amount'), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    expect(
      fake.changes.last,
      endsWith('/move {"location":"l-shelf2","amount":1}'),
    );
    // The row at the destination.
    expect(find.text('Garage/Shelf 2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('merge a row into another: say which values to keep', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    fake.stock.add({
      'id': 's-2',
      'code': '1C01',
      'item': 'i-drill',
      'location': 'l-shelf2',
      'amount': 3,
      'photo': null,
      'values': <String, Object?>{'Bought': '2026-01-05'},
      'defaulted': <String>[],
    });
    await startApp(tester, fake);
    await open(tester, '/stock/1C00');
    await menu(tester, 'Merge into…');
    // The only other counted row; where they differ, which to keep.
    expect(find.text('1C01  Garage/Shelf 2'), findsOneWidget);
    expect(find.text('The rows differ. Which to keep?'), findsOneWidget);
    expect(find.text('1C00: none'), findsOneWidget);
    expect(find.text('1C01: 2026-01-05'), findsOneWidget);
    await tester.tap(find.text('1C00: none'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'POST /api/v1/stock/s-1/merge {"into":"s-2","amount":null,'
      '"resolve":{"values":{"Bought":"from"}}}',
    );
    // On to the row merged into; the other's label is gone.
    expect(find.text('5'), findsOneWidget);
    expect((fake.stock.single['values'] as Map)['Bought'], isNull);
    expect(fake.gone, contains('1C00'));
  });

  testWidgets('search by attributes; results as a table, and back', (
    tester,
  ) async {
    setSize(tester, 1200);
    final fake = FakeServer();
    await startApp(tester, fake);

    // Nothing is searched while typing.
    await tester.enterText(find.byType(TextField).first, 'drill');
    await tester.pumpAndSettle();
    expect(find.byType(FoundItemsScreen), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');

    // A class brings its attributes, those of stock rows too; files are
    // found by their item.
    await tester.tap(find.text('Any class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    expect(field('Voltage'), findsOneWidget);
    expect(field('Bought (stock)'), findsOneWidget);
    expect(find.text('Datasheet'), findsNothing);

    // A number in another unit is refused: nothing converts.
    await tester.enterText(field('Voltage'), '>= 3 kg');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('nothing converts'), findsOneWidget);
    expect(find.byType(FoundItemsScreen), findsNothing);

    // Filters name the attribute, and choices by their text.
    await tester.enterText(field('Voltage'), '>= 12 V');
    await tester.tap(find.widgetWithText(FilterChip, 'Red'));
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(
      fake.lastWhere,
      '[{"attribute":"Colour","op":"in","value":["Red"]},'
      '{"attribute":"Voltage","op":">=","value":12}]',
    );
    expect(find.text('Found items'), findsOneWidget);
    // A table, with a column for each attribute the items show.
    expect(find.text('Where'), findsOneWidget);
    expect(find.text('Voltage'), findsOneWidget);
    expect(find.text('Colour'), findsOneWidget);
    expect(find.text('Cordless drill'), findsOneWidget);
    expect(find.text('18 V'), findsOneWidget);
    expect(find.text('Garage/Shelf 1'), findsOneWidget);
    // A default is shown as one; a long value can't make its row tall.
    expect(
      tester.widget<Text>(find.text('Red')).style?.fontStyle,
      FontStyle.italic,
    );
    expect(tester.widget<Text>(find.text('18 V')).maxLines, 3);
    expect(tester.widget<Text>(find.text('Garage/Shelf 1')).maxLines, 3);

    // Back to the form, as it was filled in.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('Voltage')).controller!.text,
      '>= 12 V',
    );
    expect(find.text('Tools/Drills'), findsOneWidget);

    await tester.enterText(field('Voltage'), '20..24');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(fake.lastWhere, contains('"op":"between","value":[20,24]'));
    expect(find.text('Nothing found.'), findsOneWidget);
  });

  testWidgets('results come a page at a time, by key', (tester) async {
    setSize(tester, 700, 900);
    final fake = FakeServer();
    for (var n = 0; n < 45; n++) {
      fake.items.add({
        'id': 'i-d${n.toString().padLeft(2, '0')}',
        'code': '2${n.toString().padLeft(3, '0')}',
        'name': 'Drill ${n.toString().padLeft(2, '0')}',
        'class': 'c-drills',
        'photo': null,
        'values': <String, Object?>{'Voltage': 12},
        'defaulted': <String>[],
      });
    }
    await startApp(tester, fake);
    await search(tester, 'drill');
    expect(fake.itemPages, [null]);
    // The first page: Cordless drill, then Drill 00 … Drill 18.
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, -20000),
      5000,
    );
    await tester.pumpAndSettle();
    expect(fake.itemPages.take(2), [null, 'i-d18']);
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, -20000),
      5000,
    );
    await tester.pumpAndSettle();
    expect(fake.itemPages, [null, 'i-d18', 'i-d38']);
    expect(find.text('Drill 44'), findsOneWidget);
  });

  testWidgets('a URL value is a link: open it, or copy it from its menu', (
    tester,
  ) async {
    setSize(tester, 400);
    final fake = FakeServer();
    const url = 'https://example.com/drill.pdf';
    (fake.items.first['values'] as Map)['Manual'] = url;
    final opened = <Uri>[];
    final before = openLink;
    openLink = (u) async {
      opened.add(u);
      return true;
    };
    addTearDown(() => openLink = before);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');

    // A tap opens it.
    await tester.tap(find.text(url));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(url)]);

    // A long press offers to open or copy it.
    await tester.longPress(find.text(url));
    await tester.pumpAndSettle();
    expect(find.text('Open link'), findsOneWidget);
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, url);
    expect(find.text('Link copied'), findsOneWidget);

    // A right click too; and in the table, a tap on the link opens it rather
    // than the item.
    setSize(tester, 1500);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await search(tester, 'drill');
    expect(find.text('Manual'), findsOneWidget);
    await tester.tap(find.text(url), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open link'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(url), Uri.parse(url)]);
    await tester.tap(find.text(url));
    await tester.pumpAndSettle();
    expect(opened, hasLength(3));
    expect(find.byType(FoundItemsScreen), findsOneWidget);
  });

  testWidgets('a class lists item and stock attributes apart', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await open(tester, '/classes/c-drills');
    expect(find.text('Item attributes'), findsOneWidget);
    expect(find.text('Stock attributes'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add'), findsWidgets);
    // An inherited one says where it comes from, and has no menu here.
    expect(find.textContaining('from Tools'), findsOneWidget);
    expect(find.byTooltip('Colour'), findsNothing);
    expect(find.byTooltip('Voltage'), findsOneWidget);

    // Tools has no stock attributes: no empty section for them.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await open(tester, '/classes/c-tools');
    expect(find.text('Item attributes'), findsOneWidget);
    expect(find.text('Stock attributes'), findsNothing);

    // A class without attributes: only the heading that holds Add.
    fake.own['c-tools']!.clear();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await open(tester, '/classes/c-tools');
    expect(find.text('Attributes'), findsOneWidget);
    expect(find.text('Item attributes'), findsNothing);
  });

  testWidgets('add an attribute: what it rewrites first, then for real', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await open(tester, '/classes/c-drills');
    await tester.tap(find.widgetWithText(TextButton, 'Add').first);
    await tester.pumpAndSettle();

    // Not the name of a field every item has.
    await tester.enterText(field('Name'), 'Amount');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(
      find.text('"Amount" is a field of every item or stock row'),
      findsOne,
    );
    expect(fake.changes, isEmpty);

    // Required, with a default: the dry run says what it gives it to.
    await tester.enterText(field('Name'), 'Brand');
    await tester.tap(find.text('Required'));
    await tester.enterText(field('Default'), 'unknown');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    const body =
        '{"name":"Brand","definition":{"scope":"item","type":"text",'
        '"required":true,"default":"unknown"}}';
    expect(fake.changes, [
      'POST /api/v1/classes/c-drills/attributes?dry_run=true $body',
    ]);
    expect(find.text('Add Brand to Drills?'), findsOneWidget);
    expect(find.text('This rewrites 1 item.'), findsOneWidget);
    expect(fake.own['c-drills']!.containsKey('Brand'), isFalse);
    await tester.tap(button('Add'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'POST /api/v1/classes/c-drills/attributes $body');
    expect(find.text('Brand *'), findsOneWidget);
    expect((fake.items.first['values'] as Map)['Brand'], 'unknown');

    // A change of one: its type and where its values live stay.
    await tester.tap(find.text('Voltage *'));
    await tester.pumpAndSettle();
    expect(find.text('Voltage in Drills'), findsOneWidget);
    expect(find.text('number, on the item.'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.enterText(field('Default'), '12');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/classes/c-drills/attributes/Voltage?dry_run=true {"default":12}',
    );
    expect(find.text('No item or stock row changes.'), findsOneWidget);
    await tester.tap(button('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/classes/c-drills/attributes/Voltage {"default":12}',
    );
    expect(find.textContaining('default 12 V'), findsOneWidget);

    // Renamed, from its menu: every value of it is rewritten.
    await tester.tap(find.byTooltip('Brand'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Brand'), 'Make');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Rename Brand to Make?'), findsOneWidget);
    await tester.tap(button('Rename'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'POST /api/v1/classes/c-drills/attributes/Brand/rename {"name":"Make"}',
    );
    expect(find.text('Make *'), findsOneWidget);
  });

  testWidgets('choices: one in use is refused, one that isn\'t goes', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await open(tester, '/classes/c-tools');
    await tester.tap(find.byTooltip('Colour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choices…'));
    await tester.pumpAndSettle();
    expect(find.text('Choices of Colour'), findsOneWidget);

    // The drill is red: refused, as the dry run says at once.
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 item has "Red"'), findsOneWidget);
    expect(find.text('Remove Red?'), findsNothing);

    await tester.tap(find.byTooltip('Remove').last);
    await tester.pumpAndSettle();
    expect(find.text('Remove Blue?'), findsOneWidget);
    await tester.tap(button('Remove'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'DELETE /api/v1/classes/c-tools/attributes/Colour/choices/Blue',
    );
    expect(find.widgetWithText(ListTile, 'Blue'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Green'), findsOneWidget);
  });

  testWidgets('a table wider than the screen says so', (tester) async {
    setSize(tester, 1200);
    await startApp(tester, FakeServer());
    await search(tester, 'drill');
    // Room for all columns: no scrollbar shown, no fade.
    expect(
      tester
          .widgetList<Scrollbar>(find.byType(Scrollbar))
          .where((s) => s.thumbVisibility == true),
      isEmpty,
    );
    expect(find.byKey(const ValueKey('more-columns')), findsNothing);

    // Narrower: the horizontal scrollbar shows, and the right edge fades
    // until the last column is in sight.
    setSize(tester, 900);
    await tester.pumpAndSettle();
    final bar = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .where((s) => s.thumbVisibility == true);
    expect(bar, hasLength(1));
    expect(bar.single.trackVisibility, isTrue);
    double fade() => tester
        .widget<AnimatedOpacity>(find.byKey(const ValueKey('more-columns')))
        .opacity;
    expect(fade(), 1);
    await tester.drag(find.text('Garage/Shelf 1'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(fade(), 0);
  });

  testWidgets('a label code finds its object, or says it is deleted', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer()..gone.add('1Z00');
    await startApp(tester, fake);
    await search(tester, '1a-01'); // case and hyphens don't matter
    expect(find.text('Label code: Location 1A01'), findsOneWidget);
    await tester.tap(find.text('Garage/Shelf 1'));
    await tester.pumpAndSettle();
    expect(find.text('Stock here'), findsOneWidget);
    expect(find.text('Cordless drill'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await search(tester, '1z00');
    expect(
      find.text("This label's item, stock row or location has been deleted"),
      findsOneWidget,
    );
  });

  testWidgets('add an item with a value, without stock', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    pickUploadFile = ({bool image = false}) async =>
        ('drill.pdf', () async => [1, 2, 3]);
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    await startApp(tester, fake);

    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a class'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Tools/')).enabled,
      isFalse,
    );
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();

    // A required value, in its unit: another one is refused.
    expect(field('Voltage *'), findsOneWidget);
    // A file is chosen on the form too, and sent once the item is made.
    expect(find.text('No file. Takes application/pdf'), findsOneWidget);
    await tester.ensureVisible(find.text('Datasheet'));
    await tester.tap(find.text('Datasheet'));
    await tester.pumpAndSettle();
    expect(find.text('drill.pdf, sent when saved'), findsOneWidget);
    await tester.enterText(field('Name'), 'Impact driver');
    await tester.enterText(field('Voltage *'), '18 mV');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('nothing converts'), findsOneWidget);
    expect(fake.changes, isEmpty);

    // With the unit's own label, or without, it is the same. Add stock is
    // on at first, and wants a location, none being known yet.
    await tester.enterText(field('Voltage *'), '18 V');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Choose a location for its stock'),
      findsOneWidget,
    );
    expect(fake.changes, isEmpty);

    // Without stock: the item alone, and its screen.
    await tester.ensureVisible(find.text('Add stock'));
    await tester.tap(find.text('Add stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.first,
      'POST /api/v1/items {"class":"c-drills","name":"Impact driver",'
      '"values":{"Voltage":18}}',
    );
    expect(fake.changes, hasLength(3));
    expect(fake.changes[1], contains('/files/Datasheet'));
    expect(fake.changes[1], contains('filename="drill.pdf"'));
    // That it had no stock is kept on the account, for the next item on
    // any device (decision 118).
    expect(
      fake.changes.last,
      'PATCH /api/v1/me/preferences {"add_stock_last":false}',
    );
    expect(fake.preferences['add_stock_last'], isFalse);
    expect(find.widgetWithText(AppBar, 'New item'), findsNothing);
    expect(find.text('Impact driver'), findsWidgets);
    expect(find.text('No stock.'), findsOneWidget);
    // The default it was given.
    expect(find.text('Red  (default)'), findsOneWidget);
  });

  testWidgets('add an item counted in metres, with its stock', (tester) async {
    setSize(tester, 1000);
    // Its class counts in metres; the item has no unit of its own.
    final fake = FakeServer()
      ..ownStock['c-drills'] = {'counting': 'optional', 'unit': 'm'};
    fake.locations.firstWhere((l) => l['id'] == 'l-shelf2')['stock_photos'] =
        true;
    pickUploadFile = ({bool image = false}) async =>
        ('reel.png', () async => [1, 2, 3]);
    addTearDown(() => pickUploadFile = ({bool image = false}) async => null);
    await startApp(tester, fake);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    expect(field('Unit of its stock'), findsNothing);
    await tester.enterText(field('Name'), 'Drill cable');
    await tester.enterText(field('Voltage *'), '230');

    // Its stock on the same form, in its class's unit.
    await tester.ensureVisible(find.text('Choose a location'));
    await tester.tap(find.text('Choose a location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garage/Shelf 2'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Amount'), '2.5 m');
    await tester.enterText(field('Bought'), '2026-11-01');
    // The stock row's photo, below the item's.
    await tester.ensureVisible(find.text('Photo').last);
    await tester.tap(find.text('Photo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // One request, both together; then the row's photo.
    expect(fake.changes, hasLength(2));
    expect(
      fake.changes.last,
      matches(RegExp(r'^PUT /api/v1/stock/s-\w+/photo')),
    );
    expect(
      fake.changes.first,
      'POST /api/v1/items {"class":"c-drills","name":"Drill cable",'
      '"values":{"Voltage":230},"stock":{"location":"l-shelf2",'
      '"amount":2.5,"values":{"Bought":"2026-11-01"}}}',
    );
    // Then the item's screen shows it.
    expect(find.widgetWithText(AppBar, 'New item'), findsNothing);
    expect(find.text('Drill cable'), findsWidgets);
    expect(find.text('2.5 m'), findsOneWidget);
    expect(find.text('2026-11-01'), findsOneWidget);
  });

  testWidgets('one item after another: class, stock and location carry over', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer()
      ..ownStock['c-drills'] = {'counting': 'optional', 'unit': 'm'};
    await startApp(tester, fake);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Drill cable');
    await tester.enterText(field('Voltage *'), '230');
    await tester.ensureVisible(find.text('Choose a location'));
    await tester.tap(find.text('Choose a location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garage/Shelf 2'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Amount'), '2.5 m');
    await tester.tap(find.text('Create and add another'));
    await tester.pumpAndSettle();
    expect(fake.changes.single, contains('"stock":{"location":"l-shelf2"'));

    // The next item's form: the class of the last item, its stock at the
    // same place; ready for the name.
    expect(find.widgetWithText(AppBar, 'New item'), findsOneWidget);
    expect(find.text('Tools/Drills'), findsOneWidget);
    expect(find.text('Garage/Shelf 2'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    final name = tester.widget<EditableText>(
      find.descendant(of: field('Name'), matching: find.byType(EditableText)),
    );
    expect(name.focusNode.hasFocus, isTrue);
    await tester.enterText(field('Name'), 'Extension cable');
    await tester.enterText(field('Voltage *'), '230');
    // Enter in Manual, the item's last field, goes on: the stock's fields
    // come after it.
    await tester.enterText(field('Manual'), '');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(fake.changes, hasLength(1));
    await tester.enterText(field('Amount'), '10');
    // Enter in Bought, the stock's last field, creates both.
    await tester.enterText(field('Bought'), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fake.changes.last, contains('"name":"Extension cable"'));
    expect(fake.changes.last, contains('"location":"l-shelf2","amount":10'));
    expect(find.text('Extension cable'), findsWidgets);

    // Add stock turned off stays off for the next new item; Enter in the
    // item's last field then creates it.
    clearMessages(tester);
    await tester.tap(find.text('Items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add stock'));
    await tester.tap(find.text('Add stock'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Hook');
    await tester.enterText(field('Voltage *'), '12');
    await tester.enterText(field('Manual'), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      fake.changes.lastWhere((c) => c.startsWith('POST /api/v1/items')),
      isNot(contains('"stock"')),
    );
    // Kept on the account, for every device (decision 118).
    expect(fake.preferences['add_stock_last'], isFalse);
    clearMessages(tester);
    await tester.tap(find.text('Items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('Add stock with a new item: a preference of the account', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    bool addStock() =>
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;
    Future<void> newItem() async {
      clearMessages(tester);
      await tester.tap(find.text('Items'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New item'));
      await tester.pumpAndSettle();
    }

    // On the Preferences tab, for this account; as last time at first.
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await openTab(tester, 'Preferences');
    expect(find.text('For this account, on every device'), findsOneWidget);
    expect(
      find.text('As for the last item added, on any device: on now.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/me/preferences {"add_stock":"off"}',
    );
    expect(
      find.text('The new-item form starts with Add stock off.'),
      findsOneWidget,
    );
    await newItem();
    expect(addStock(), isFalse);

    // Another device changes it: this one is told, and asks again.
    fake.preferences['add_stock'] = 'on';
    fake.sendEvent('preferences');
    await tester.pumpAndSettle();
    await newItem();
    expect(addStock(), isTrue);

    // As last time, with the last item added on another device.
    fake.preferences
      ..['add_stock'] = 'last'
      ..['add_stock_last'] = false;
    fake.sendEvent('preferences');
    await tester.pumpAndSettle();
    await newItem();
    expect(addStock(), isFalse);
  });

  testWidgets('the Account tabs fit a narrow phone, or scroll', (tester) async {
    setSize(tester, 320, 700);
    await startApp(tester, FakeServer());
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    for (final tab in ['About', 'Sessions', 'Preferences', 'Account']) {
      await openTab(tester, tab);
    }
    expect(find.text('anna@example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a class says how its stock is counted, and the forms follow', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);

    // The class screen: the default, as no class has a rule of its own.
    await open(tester, '/classes/c-drills');
    expect(
      find.text('Stock: counted, the amount optional · pieces'),
      findsOneWidget,
    );
    expect(find.text('the default'), findsOneWidget);

    // Counting in metres relabels the drill's 2 pieces: asked first, after
    // a dry run.
    await tester.tap(find.text('Stock: counted, the amount optional · pieces'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Counted, the amount required'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Unit'), 'm');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Count in another unit?'), findsOneWidget);
    expect(find.textContaining('1 stock row is counted'), findsOneWidget);
    expect(
      fake.changes.single,
      'PUT /api/v1/classes/c-drills/stock?dry_run=true '
      '{"counting":"required","unit":"m"}',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Change'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PUT /api/v1/classes/c-drills/stock {"counting":"required","unit":"m"}',
    );
    expect(
      find.text('Stock: counted, the amount required · m'),
      findsOneWidget,
    );
    expect(find.text('its own'), findsOneWidget);

    // A new item's stock needs an amount now, in metres.
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    expect(field('Amount *'), findsOneWidget);
    await tester.enterText(field('Name'), 'Drill cable');
    await tester.enterText(field('Voltage *'), '230');
    await tester.ensureVisible(find.text('Choose a location'));
    await tester.tap(find.text('Choose a location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garage/Shelf 2'));
    await tester.pumpAndSettle();
    final before = fake.changes.length;
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(fake.changes, hasLength(before));
    await tester.enterText(field('Amount *'), '2.5 m');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      contains('"stock":{"location":"l-shelf2","amount":2.5'),
    );

    // Not counted: no amount at all, on the new item's form and on the
    // stock form.
    fake.ownStock['c-drills'] = {'counting': 'none', 'unit': null};
    clearMessages(tester);
    await open(tester, '/items/new?class=c-drills');
    expect(field('Amount'), findsNothing);
    expect(field('Amount *'), findsNothing);
    expect(find.textContaining('Its class: not counted.'), findsOneWidget);
    await open(tester, '/stock/new?item=i-drill');
    expect(find.text('Cordless drill  (1B00)'), findsOneWidget);
    expect(field('Amount'), findsNothing);
  });

  testWidgets('on a phone, the keyboard comes only when asked for', (
    tester,
  ) async {
    // Tests run as on Android.
    setSize(tester, 400);
    await startApp(tester, FakeServer());
    EditableText search() => tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextField).first,
        matching: find.byType(EditableText),
      ),
    );
    // Not at the start: the search field waits for a tap.
    expect(search().focusNode.hasFocus, isFalse);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(search().focusNode.hasFocus, isTrue);
    // A tap outside it puts the keyboard away.
    await tester.tapAt(const Offset(200, 500));
    await tester.pumpAndSettle();
    expect(search().focusNode.hasFocus, isFalse);
  });

  testWidgets('a class made just now is the next item\'s', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Classes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New class'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Saws');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Items'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    expect(find.text('Saws'), findsOneWidget);
  });

  testWidgets(
    'different API revisions: a bar until OK, again when one changes',
    (tester) async {
      setSize(tester, 1000);
      final fake = FakeServer();
      final storage = MemoryStorage();
      // The app started, with the same storage each time.
      Future<void> start() async {
        await tester.pumpWidget(const SizedBox());
        final session = Session(storage: storage, httpClient: fake.client);
        await session.login('anna@example.com', 'secret', server: server);
        await tester.pumpWidget(WtfApp(session: session));
        await tester.pumpAndSettle();
      }

      final bar = find.textContaining("The server's API is");

      // The same revision: no bar, and on the Account page the app and the
      // server each have API version 1.1, under their builds.
      await start();
      expect(bar, findsNothing);
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      await openTab(tester, 'About');
      expect(
        find.text('Build date not known\nAPI version: 1.1'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          RegExp(r'commit 70ef34d of .*\nAPI version: 1\.1$'),
        ),
        findsOneWidget,
      );

      // The server is updated while the app runs: its next answer warns,
      // the app being the older one.
      fake.revision = 2;
      await tester.tap(find.text('Items'));
      await tester.pumpAndSettle();
      await search(tester, 'drill');
      expect(bar, findsOneWidget);
      expect(find.textContaining('newer than this app'), findsOneWidget);
      expect(find.textContaining('Update the app.'), findsOneWidget);

      // OK confirms it, also after a restart.
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      await start();
      expect(bar, findsNothing);
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      await openTab(tester, 'About');
      expect(find.textContaining('API version: 1.2'), findsOneWidget);

      // Another revision warns again: here an older server.
      fake.revision = 0;
      await start();
      expect(find.textContaining('older than this app'), findsOneWidget);
      expect(find.textContaining('Update the server (wtfd).'), findsOneWidget);

      // What was confirmed is kept by the server's address.
      expect(storage.revisionsConfirmed, {'http://wtf.test:8080': '2/1'});
    },
  );

  testWidgets('the location tree, and a box with compartments', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);

    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    expect(find.text('Garage/'), findsOneWidget);
    expect(find.text('Shelf 1'), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('Shelf 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PhotoOrIcon),
        matching: find.byIcon(Icons.folder_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('New location'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Box');
    await tester.tap(find.text('Compartment grid'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Columns'), '2');
    await tester.enterText(field('Rows'), '3');
    await tester.pump();
    expect(find.textContaining('6 compartments, A1 … B3'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(
      fake.changes.single,
      'POST /api/v1/locations {"name":"Box","parent":null,"container":false,'
      '"grid":{"columns":2,"rows":3}}',
    );
    expect(find.text('Container'), findsOneWidget);
    expect(find.text('B3'), findsOneWidget);
    // The tree underneath already shows the new box.
    expect(find.text('Box/', skipOffstage: false), findsOneWidget);
  });

  testWidgets('edit an item: fields and values in one change', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    // The number in the field, its unit after it. It reads back unchanged.
    expect(
      tester.widget<TextFormField>(field('Voltage *')).controller!.text,
      '18',
    );
    expect(
      find.descendant(of: field('Voltage *'), matching: find.text('V')),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.changes, isEmpty);
    expect(find.text('No changes.'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Old drill');
    await tester.enterText(field('Voltage *'), '14.4');
    final colour = find.descendant(
      of: find.byType(DropdownMenuFormField<String>),
      matching: find.byType(TextField),
    );
    // It follows the class's default, and says so.
    expect(find.text("The class's default"), findsOneWidget);
    await tester.enterText(colour, 'Blue');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.changes, [
      'PATCH /api/v1/items/i-drill '
          '{"values":{"Colour":"Blue","Voltage":14.4},"name":"Old drill"}',
    ]);
    expect(find.text('14.4 V'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);

    // Back to the default: it follows the class's default again.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to the default (Red)'));
    await tester.pumpAndSettle();
    expect(find.text("The class's default"), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/items/i-drill {"default":["Colour"]}',
    );
    expect(find.text('Red  (default)'), findsOneWidget);

    // A required value without a default can't be cleared.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Voltage *'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(fake.changes, hasLength(2));
  });

  testWidgets('delete a location with stock in it only when told to', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await search(tester, '1A00');
    await tester.tap(find.text('Garage'));
    await tester.pumpAndSettle();

    await menu(tester, 'Delete…');
    expect(find.text('Delete location Garage?'), findsOneWidget);
    expect(find.text('And the 2 locations below it:'), findsOneWidget);
    expect(find.text('1 stock row is in them:'), findsOneWidget);
    expect(find.text("This can't be undone."), findsOneWidget);
    // Delete stays disabled until the stock may go too.
    final delete = find.widgetWithText(FilledButton, 'Delete');
    expect(tester.widget<FilledButton>(delete).onPressed, isNull);
    await tester.tap(find.text('Delete that stock too'));
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(
      fake.changes.single,
      'DELETE /api/v1/locations/l-garage?recursive=true&force=true',
    );
    expect(fake.locations, isEmpty);
    expect(fake.stock, isEmpty);
  });

  testWidgets('deleting asks first, as it can\'t be undone', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await open(tester, '/stock/1C00');
    await menu(tester, 'Delete…');
    expect(find.text('Delete this stock row?'), findsOneWidget);
    expect(find.textContaining("This can't be undone."), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fake.changes.single, 'DELETE /api/v1/stock/s-1');
    // Its label now says what became of it.
    await open(tester, '/stock/1C00');
    expect(
      find.text("This label's item, stock row or location has been deleted."),
      findsOneWidget,
    );
  });

  testWidgets('viewers get no buttons that would be refused', (tester) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer(role: 'viewer'));
    expect(find.text('New item'), findsNothing);
    expect(find.text('Admin'), findsNothing);
    await openItem(tester, 'Cordless drill');
    expect(find.text('Add stock'), findsNothing);
    expect(find.byTooltip('Edit'), findsNothing);
    // A file attribute without a file isn't listed for them.
    expect(find.text('Datasheet'), findsNothing);
    // Nor do they get a preference for adding items.
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await openTab(tester, 'Preferences');
    expect(find.text('Add stock with a new item'), findsNothing);
    expect(find.text('On this device'), findsOneWidget);
  });

  testWidgets('users keep items and stock; admins set up the rest', (
    tester,
  ) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer(role: 'user'));
    final rail = find.byType(NavigationRail);
    expect(
      find.descendant(of: rail, matching: find.text('Admin')),
      findsNothing,
    );
    expect(find.text('New item'), findsOneWidget);
    await openItem(tester, 'Cordless drill');
    expect(find.text('Add stock'), findsOneWidget);
    expect(find.byTooltip('Edit'), findsOneWidget);

    // Locations: no new ones, no changing them, nor their photos; stock,
    // yes.
    await tester.tap(
      find.descendant(of: rail, matching: find.text('Locations')),
    );
    await tester.pumpAndSettle();
    expect(find.text('New location'), findsNothing);
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/locations/1A01');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(PopupMenuButton<String>),
      ),
      findsNothing,
    );
    expect(find.text('Add stock here'), findsOneWidget);

    // Admin screens, even by URL, lead to Items.
    for (final path in ['/admin', '/classes/c-drills', '/accounts']) {
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationRail>(rail).selectedIndex,
        0,
        reason: path,
      );
      expect(find.text('New item'), findsOneWidget, reason: path);
    }
  });

  testWidgets('a phone as the camera for a computer: what for, a photo, stop', (
    tester,
  ) async {
    setSize(tester, 400, 1400);
    final fake = FakeServer();
    final camera = canTakePhoto;
    canTakePhoto = (_) => true;
    takeCameraPhoto = () async => ('shot.jpg', () async => [1, 2, 3]);
    addTearDown(() {
      canTakePhoto = camera;
      takeCameraPhoto = () async => null;
    });
    await startApp(tester, fake);
    expect(fake.openStreams, 1);

    // The camera for another session, chosen under Account: the app shows
    // only the camera, and has no event stream.
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    await openTab(tester, 'Sessions');
    await tester.tap(find.byTooltip('Be its camera'));
    await tester.pumpAndSettle();
    expect(fake.cameraFor, 'sess-phone');
    expect(
      find.text('Photos go to what WtF on Android has open.'),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsNothing);
    expect(fake.openStreams, 0);
    FilledButton shutter() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Take photo'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );

    // Nothing open there: no photo. A new item's form: its photo goes into
    // the form, sent when it is saved.
    expect(find.text('Open an item on the computer'), findsOneWidget);
    expect(shutter().onPressed, isNull);
    fake.cameraTarget = {'waiting': 'item'};
    await tester.pump(cameraPoll);
    await tester.pumpAndSettle();
    expect(find.text('A new item'), findsOneWidget);
    expect(
      find.text('Its photo, on its form; sent when it is saved'),
      findsOneWidget,
    );
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(fake.heldPhoto, isNotNull);
    expect(find.text('In the form of the new item'), findsOneWidget);
    fake.heldPhoto = null;

    // A saved item: the photo goes to it.
    fake.cameraTarget = {
      'type': 'item',
      'id': 'i-drill',
      'name': 'Cordless drill',
    };
    await tester.pump(cameraPoll);
    await tester.pumpAndSettle();
    expect(find.text('Cordless drill'), findsOneWidget);
    expect(find.text('The photo of this item'), findsOneWidget);
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      startsWith('PUT /api/v1/me/camera/photo?session=sess-phone'),
    );
    expect(fake.changes.last, contains('filename="shot.jpg"'));
    expect(fake.items.first['photo'], isNotNull);
    expect(find.text('Added to Cordless drill'), findsOneWidget);

    // The computer moved on before the photo arrived: it says so, and the
    // photo can be sent again.
    fake.cameraTarget = {};
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(find.text('Open an item on the computer'), findsNWidgets(2));
    fake.cameraTarget = {
      'type': 'stock',
      'id': 's-1',
      'name': 'Cordless drill · Garage/Shelf 1',
    };
    await tester.tap(find.text('Send again'));
    await tester.pumpAndSettle();
    expect(find.text('Added to Cordless drill · Garage/Shelf 1'), findsOne);
    expect(fake.stock.first['photo'], isNotNull);

    // Back from a locked screen, it asks at once.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    fake.cameraTarget = {
      'type': 'location',
      'id': 'l-shelf1',
      'name': 'Shelf 1',
    };
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('The photo of this location'), findsOneWidget);

    // Stop: the app as before, with its event stream.
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(fake.cameraFor, isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(fake.openStreams, 1);
  });

  testWidgets('the computer says what it has open once it has a camera, '
      'loads again without losing what is typed, and puts its photo in a '
      'form', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await openItem(tester, 'Cordless drill');
    expect(fake.targets, isEmpty);

    // A phone becomes its camera: a bar says so, and the server is told
    // what is open.
    fake.sendEvent('camera', {'client': 'WtF on iPhone'});
    await tester.pumpAndSettle();
    expect(find.text('Camera: WtF on iPhone'), findsOneWidget);
    const drill = {'type': 'item', 'id': 'i-drill', 'name': 'Cordless drill'};
    expect(fake.targets, [drill]);

    // A photo taken on the phone: the item's screen loads again.
    fake.items.first['name'] = 'Hammer drill';
    fake.sendEvent('changed', {'path': '/items/i-drill/photo'});
    await tester.pumpAndSettle();
    expect(find.text('Hammer drill'), findsWidgets);
    expect(fake.targets.last, {...drill, 'name': 'Hammer drill'});

    // Its form: the same item, in a form, where a photo goes; what is
    // typed stays, while the item's screen under it loads again.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(fake.targets.last, {...drill, 'name': 'Hammer drill', 'form': true});
    await tester.enterText(field('Name'), 'Typed name');
    fake.items.first['name'] = 'Another name';
    fake.sendEvent('changed', {'path': '/items/i-drill/photo'});
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('Name')).controller!.text,
      'Typed name',
    );
    expect(fake.targets.last, {...drill, 'name': 'Another name', 'form': true});

    // A photo the phone took for the form is the item's there, sent when
    // it is saved.
    fake.heldPhoto = [1, 2, 3];
    fake.sendEvent('photo', {'client': 'WtF on iPhone'});
    await tester.pumpAndSettle();
    expect(find.text('Photo.png, sent when saved'), findsOneWidget);
    expect(fake.heldPhoto, isNull);

    // A new item isn't saved yet: its form takes the photo too. A list is
    // nothing a photo is for.
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    router.go('/items/new');
    await tester.pumpAndSettle();
    expect(fake.targets.last, {'waiting': 'item'});
    fake.heldPhoto = [1, 2, 3];
    fake.sendEvent('photo', {'client': 'WtF on iPhone'});
    await tester.pumpAndSettle();
    expect(find.text('Photo.png, sent when saved'), findsOneWidget);
    router.go('/locations');
    await tester.pumpAndSettle();
    expect(fake.targets.last, isEmpty);

    // The phone stops: the bar goes, and nothing more is said.
    fake.sendEvent('camera');
    await tester.pumpAndSettle();
    expect(find.text('Camera: WtF on iPhone'), findsNothing);
    final before = fake.targets.length;
    router.go('/items/1B00');
    await tester.pumpAndSettle();
    expect(fake.targets.length, before);
  });

  testWidgets('a camera goes on after a restart, until its computer logs out', (
    tester,
  ) async {
    setSize(tester, 400, 1000);
    final fake = FakeServer();
    final storage = MemoryStorage(
      camera: jsonEncode({'session': 'sess-phone', 'client': 'WtF on Android'}),
    );
    final session = Session(storage: storage, httpClient: fake.client);
    await session.login('anna@example.com', 'secret', server: server);
    await tester.pumpWidget(WtfApp(session: session));
    await tester.pumpAndSettle();
    expect(
      find.text('Photos go to what WtF on Android has open.'),
      findsOneWidget,
    );

    fake.cameraGone = true;
    await tester.pump(cameraPoll);
    await tester.pumpAndSettle();
    expect(
      find.text(
        "WtF on Android isn't logged in any more: no longer its camera.",
      ),
      findsOneWidget,
    );
    expect(storage.camera, isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
