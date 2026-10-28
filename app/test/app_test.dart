import 'dart:convert';
import 'dart:io' show HandshakeException;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:wtf/api/models.dart';
import 'package:wtf/app.dart';
import 'package:wtf/screens/attribute_screens.dart';
import 'package:wtf/screens/search_screen.dart';
import 'package:wtf/session.dart';
import 'package:wtf/theme.dart';
import 'package:wtf/widgets/attachments.dart';
import 'package:wtf/widgets/link.dart';
import 'package:wtf/widgets/pickers.dart';

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

Finder field(String label) => find.widgetWithText(TextFormField, label);

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

  testWidgets('log in, see the account, log out', (tester) async {
    setSize(tester, 400, 800);
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
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    // The search screen, with the bottom bar of a narrow screen.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.textContaining('Search items by name'), findsOneWidget);
    expect(storage.server, 'http://wtf.test:8080');
    expect(storage.token, 'tok');

    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    expect(find.text('anna@example.com'), findsOneWidget);
    await tester.ensureVisible(find.text('Log out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('Manage holds attributes, units and accounts', (tester) async {
    setSize(tester, 400, 800);
    await startApp(tester, FakeServer());
    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    expect(find.text('Units'), findsOneWidget);
    // This account may not read accounts.
    expect(find.text('Accounts'), findsNothing);
    await tester.tap(find.text('Attributes'));
    await tester.pumpAndSettle();
    expect(find.text('Voltage'), findsOneWidget);
    // Still under Manage.
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
  });

  testWidgets('units by quantity, then by family', (tester) async {
    setSize(tester, 400, 800);
    final fake = FakeServer();
    const length = {'id': 'q-length', 'name': 'Length', 'datatype': 'float'};
    Map<String, dynamic> family(
      String id,
      String name,
      List<List<Object>> units,
    ) => {
      'id': id,
      'name': name,
      'quantity': length,
      'units': [
        for (final [uid, unitName, symbol, factor] in units)
          {
            'id': uid,
            'name': unitName,
            'symbol': symbol,
            'family': {'id': id, 'name': name},
            'quantity': length,
            'base_factor': factor,
            'base_offset': 0,
          },
      ],
    };
    fake.families.insertAll(0, [
      family('f-metric', 'Metric length', [
        ['u-mm', 'millimetre', 'mm', 0.001],
        ['u-m', 'metre', 'm', 1],
      ]),
      family('f-imperial', 'Imperial length', [
        ['u-in', 'inch', 'in', 0.0254],
      ]),
    ]);
    await startApp(tester, fake);
    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Units'));
    await tester.pumpAndSettle();

    // Quantities first, naming their families.
    expect(find.text('Length'), findsOneWidget);
    expect(find.text('Metric length · Imperial length'), findsOneWidget);
    expect(find.text('Voltage'), findsWidgets);
    expect(find.text('millimetre'), findsNothing);
    // An arrow says a quantity opens, left of its switch.
    final arrow = find.descendant(
      of: find.ancestor(
        of: find.text('Length'),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.expand_more),
    );
    expect(arrow, findsOneWidget);
    expect(
      tester.getCenter(arrow).dx,
      lessThan(tester.getCenter(find.text('Length')).dx),
    );

    await tester.tap(find.text('Length'));
    await tester.pumpAndSettle();
    expect(find.text('mm, m'), findsOneWidget);
    await tester.tap(find.text('Metric length'));
    await tester.pumpAndSettle();
    expect(find.text('millimetre'), findsOneWidget);
    expect(find.text('base unit'), findsOneWidget);

    // A filter opens what matches.
    await tester.enterText(find.byType(TextField), 'inch');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'inch'), findsOneWidget);
    // Under Length, and as Length's only family in its subtitle.
    expect(find.text('Imperial length'), findsNWidgets(2));
    expect(find.text('Metric length'), findsNothing);
    expect(find.text('Voltage'), findsNothing);

    // A family turned off: its switch, then a way back to the default.
    Finder switchOf(String name) => find.descendant(
      of: find.ancestor(
        of: find.text(name).last,
        matching: find.byType(ListTile),
      ),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(switchOf('Imperial length')).value, isTrue);
    await tester.tap(switchOf('Imperial length'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/unit-families/f-imperial {"available":false}',
    );
    expect(tester.widget<Switch>(switchOf('Imperial length')).value, isFalse);
    await tester.tap(find.byTooltip('Back to the default (on)'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/unit-families/f-imperial {"available":null}',
    );
    expect(tester.widget<Switch>(switchOf('Imperial length')).value, isTrue);

    // Switched back on, it is the default again: no way back is offered.
    await tester.tap(switchOf('Imperial length'));
    await tester.pumpAndSettle();
    await tester.tap(switchOf('Imperial length'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchOf('Imperial length')).value, isTrue);
    expect(find.byTooltip('Back to the default (on)'), findsNothing);

    // A unit of a family that is off can't be chosen.
    await tester.tap(switchOf('Imperial length'));
    await tester.pumpAndSettle();
    final inches = find.text('in').evaluate().length; // on the screen behind
    pickUnit(tester.element(find.byType(UnitsScreen)));
    await tester.pumpAndSettle();
    expect(find.text('Choose a unit'), findsOneWidget);
    expect(find.text('mm'), findsOneWidget);
    expect(find.text('in'), findsNWidgets(inches));
  });

  testWidgets('import a unit file: a preview first, then the units', (
    tester,
  ) async {
    setSize(tester, 400, 800);
    final fake = FakeServer();
    String file = '';
    pickUnitFile = () async => (name: 'pressure.json', text: file);
    addTearDown(() => pickUnitFile = () async => null);
    await startApp(tester, fake);
    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Units'));
    await tester.pumpAndSettle();

    // Conflicts: shown, and nothing to press but Close.
    file = jsonEncode({
      'format': 'wtf-units',
      'version': 1,
      'quantities': [
        {
          'name': 'Voltage',
          'base_unit': {'symbol': 'mV', 'name': 'millivolt'},
        },
      ],
    });
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Import pressure.json'), findsOneWidget);
    expect(find.textContaining('Nothing can be imported'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Import'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(fake.unitImports.single.$2, isTrue); // only the dry run

    // A file that adds: the preview names it all, and Import imports it.
    file =
        '{"format": "wtf-units", "version": 1, "name": "Pressure", "quantities": [{'
        '"name": "Pressure", "base_unit": {"symbol": "Pa", "name": "pascal"}, '
        '"families": [{"name": "Pascals", "units": ['
        '{"symbol": "Pa", "name": "pascal", "factor": "1"}, '
        '{"symbol": "kPa", "name": "kilopascal", "factor": "1000"}]}]}, {'
        '"name": "Voltage", "base_unit": {"symbol": "V", "name": "volt"}, '
        '"families": [{"name": "Voltage", "units": ['
        '{"symbol": "V", "name": "volt", "factor": "1"}]}]}]}';
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Import Pressure (pressure.json)'), findsOneWidget);
    expect(find.textContaining('Pressure › Pascals'), findsWidgets);
    expect(find.textContaining('Pa, kPa'), findsOneWidget);
    expect(find.textContaining('there already'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    // The file goes as it was chosen, factors as written.
    expect(fake.unitImports.last, (file, false));
    expect(
      find.text('Imported 2 units, 1 unit family and 1 quantity.'),
      findsOneWidget,
    );
    // The screen shows the new quantity at once.
    expect(find.text('Pressure'), findsOneWidget);
  });

  testWidgets('the item photo: beside the details, or above the stock', (
    tester,
  ) async {
    final fake = FakeServer();
    fake.itemAttachments['i-drill'] = [
      {
        'id': 'att-1',
        'title': 'Front',
        'type': 'image/png',
        'size': 3,
        'hash': 'ab',
      },
      {
        'id': 'att-2',
        'title': 'Manual',
        'type': 'application/pdf',
        'size': 2048,
        'hash': 'cd',
      },
    ];
    fake.items.first['photo'] = 'att-1';
    final place = fake.stock.firstWhere((s) => s['item'] == 'i-drill');
    fake.locations.firstWhere((l) => l['id'] == place['location'])['photo'] = {
      'id': 'att-place',
      'title': 'Shelf',
      'type': 'image/png',
      'size': 3,
      'hash': 'ef',
    };

    // Wide: small photos in the results table, the photo right of the
    // details, which include the values without a header of their own.
    setSize(tester, 1200);
    await startApp(tester, fake);
    await search(tester, 'drill');
    expect(find.byType(Thumbnail), findsOneWidget);
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    expect(find.text('Values'), findsNothing);
    final photo = tester.getRect(find.byType(ObjectPhoto));
    final code = tester.getRect(find.text('Code'));
    expect(photo.left, greaterThan(code.right));
    expect(photo.top, lessThan(tester.getRect(find.text('Voltage')).bottom));

    // One list of attachments: the image with its small version, named as
    // the item photo, and the file with its type's icon.
    final list = find.byType(AttachmentList);
    expect(
      find.descendant(of: list, matching: find.byType(Thumbnail)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Manual'),
        matching: find.byIcon(Icons.picture_as_pdf_outlined),
      ),
      findsOneWidget,
    );
    expect(find.text('Item photo · image/png · 3 B'), findsOneWidget);

    // Images are decoded for the size they're shown at: a small one at
    // twice its size (to crop sharply), the photo at most as wide as its
    // box, here 240 by 320.
    ResizeImage decoded(Finder of) =>
        tester
                .widget<Image>(
                  find.descendant(of: of, matching: find.byType(Image)),
                )
                .image
            as ResizeImage;
    final small = decoded(find.byType(Thumbnail).first);
    expect((small.width, small.height), (96, 96));
    final big = decoded(find.byType(ObjectPhoto));
    expect((big.width, big.height), (240, 320));

    // A stock row is shown as its place, with the location's photo.
    expect(
      find.byWidgetPredicate(
        (w) => w is Thumbnail && w.attachment.id == 'att-place',
      ),
      findsOneWidget,
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
    expect(narrow.bottom, lessThan(tester.getRect(find.text('Stock')).top));
    expect(narrow.width, 400 - 32);

    // On the location, the stock row has its item's photo; a row's own
    // photo comes first, there and on the item.
    Thumbnail? thumbnail(String id) => tester
        .widgetList<Thumbnail>(find.byType(Thumbnail))
        .where((t) => t.attachment.id == id)
        .firstOrNull;
    final location = fake.locations.firstWhere(
      (l) => l['id'] == place['location'],
    );
    final router = GoRouter.of(tester.element(find.byType(ObjectPhoto)));
    router.push('/locations/${location['code']}');
    await tester.pumpAndSettle();
    expect(thumbnail('att-1'), isNotNull);
    expect(thumbnail('att-1')!.attachment.owner, '/items/i-drill');

    place['photo'] = {
      'id': 'att-row',
      'title': 'Label',
      'type': 'image/png',
      'size': 3,
      'hash': '12',
    };
    await tester.pageBack();
    await tester.pumpAndSettle();
    router.push('/locations/${location['code']}');
    await tester.pumpAndSettle();
    expect(thumbnail('att-row'), isNotNull);
    expect(thumbnail('att-1'), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle(); // pull to refresh the item
    expect(thumbnail('att-row'), isNotNull);
    expect(thumbnail('att-place'), isNull);
  });

  testWidgets('an attachment: change its title, then delete it', (
    tester,
  ) async {
    setSize(tester, 700);
    final fake = FakeServer();
    fake.itemAttachments['i-drill'] = [
      {
        'id': 'att-1',
        'title': 'Manual',
        'type': 'application/pdf',
        'size': 2048,
        'hash': 'ab',
      },
    ];
    await startApp(tester, fake);
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('application/pdf · 2.0 KiB'), findsOneWidget);

    await tester.tap(find.byTooltip('Attachment'));
    await tester.pumpAndSettle();
    expect(find.text('Make it the item photo'), findsNothing); // not an image
    await tester.tap(find.text('Title…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Manual'),
      'Datasheet',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PATCH /api/v1/items/i-drill/attachments/att-1 {"title":"Datasheet"}',
    );
    expect(find.text('Datasheet'), findsOneWidget);

    await tester.tap(find.byTooltip('Attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text("It can't be restored."), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fake.changes.last, 'DELETE /api/v1/items/i-drill/attachments/att-1');
    expect(find.text('Datasheet'), findsNothing);
  });

  testWidgets('attach a file, open it, and restore a deleted one', (
    tester,
  ) async {
    setSize(tester, 700);
    final fake = FakeServer();
    pickAttachmentFiles = () async => [
      ('front.png', () async => [1, 2, 3]),
    ];
    addTearDown(() => pickAttachmentFiles = () async => []);
    await startApp(tester, fake);
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();

    // One file: a title, and for an image, "make it the photo".
    await tester.tap(find.text('Add files'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'front.png'),
      'Front',
    );
    await tester.tap(find.text('Make it the item photo'));
    await tester.tap(find.widgetWithText(FilledButton, 'Attach'));
    await tester.pumpAndSettle();
    final upload = fake.changes.last;
    expect(upload, startsWith('POST /api/v1/items/i-drill/attachments'));
    expect(upload, contains('filename="front.png"'));
    expect(upload.toLowerCase(), contains('content-type: image/png'));
    expect(upload, contains('name="title"'));
    final a = fake.itemAttachments['i-drill']!.single;
    expect(a['title'], 'Front');
    expect(fake.items.first['photo'], a['id']);
    expect(find.text('Attached front.png.'), findsOneWidget);

    // A file opens on its own screen; a deleted one can be restored there.
    a
      ..['type'] = 'application/pdf'
      ..['title'] = 'Manual'
      ..['deleted'] = true;
    fake.items.first.remove('photo');
    await tester.tap(find.byTooltip('Edit')); // any change reloads the item
    await tester.pageBack();
    await tester.pumpAndSettle();
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This attachment is deleted'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'POST /api/v1/items/i-drill/attachments/${a['id']}/restore {}',
    );
    expect(find.textContaining('This attachment is deleted'), findsNothing);
    expect(find.text('3 B'), findsOneWidget);

    // Download, named as the server names it.
    final saved = <(String, List<int>)>[];
    saveDownloadedFile = (name, bytes) async => saved.add((name, bytes));
    addTearDown(() => saveDownloadedFile = (name, bytes) async {});
    // The message about the upload is gone by now.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    // A PDF opens, so Download is beside the title.
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.$1, 'Manual.pdf');
    expect(saved.single.$2, [1, 2, 3]);

    // Open: with the device's own app, from a file named for its type.
    final opened = <(String, List<int>)>[];
    openDownloadedFile = (a, name, bytes) async {
      opened.add((name, bytes));
      return true;
    };
    addTearDown(() => openDownloadedFile = (a, name, bytes) async => false);
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Open'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(opened.single.$1, 'Manual.pdf');
    expect(opened.single.$2, [1, 2, 3]);

    // The menu of a file offers both.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download…'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(2));
    await tester.tap(find.byTooltip('Attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));

    // A type nothing should run from here is Download only.
    a['type'] = 'application/x-msdownload';
    await tester.tap(find.byTooltip('Edit')); // any change reloads the item
    await tester.pageBack();
    await tester.pumpAndSettle();
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attachment'));
    await tester.pumpAndSettle();
    expect(find.text('Download…'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FloatingActionButton, 'Download'), findsOne);
    expect(find.widgetWithText(FloatingActionButton, 'Open'), findsNothing);
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

  test('Open: what each app offers, and the file it opens', () {
    Attachment file(String title, String type) =>
        Attachment(id: 'x', owner: '/items/i', title: title, type: type);
    // The web app: what the browser shows itself.
    expect(canOpen(file('a', 'application/pdf'), web: true), isTrue);
    expect(canOpen(file('a', 'image/png'), web: true), isTrue);
    expect(canOpen(file('a', 'image/svg+xml'), web: true), isFalse);
    expect(canOpen(file('a', 'application/zip'), web: true), isFalse);
    // The native apps: documents too, nothing that runs.
    expect(canOpen(file('a', 'application/zip'), web: false), isTrue);
    expect(canOpen(file('a', 'text/html'), web: false), isFalse);
    expect(canOpen(file('a', 'image/svg+xml'), web: false), isFalse);
    expect(canOpen(file('a', 'application/msword'), web: false), isFalse);
    expect(canOpen(file('a', 'application/x-msdownload'), web: false), isFalse);

    // Always the type's extension, and nothing a shell would act on.
    expect(openFileName(file('Datasheet', 'application/pdf')), 'Datasheet.pdf');
    expect(openFileName(file('manual.PDF', 'application/pdf')), 'manual.pdf');
    expect(openFileName(file('photo.jpeg', 'image/jpeg')), 'photo.jpg');
    expect(openFileName(file('setup.exe', 'image/png')), 'setup.exe.png');
    expect(
      openFileName(file('Tools & "parts"/2.pdf', 'application/pdf')),
      'Tools _ _parts__2.pdf',
    );
    expect(openFileName(file('...', 'text/plain')), 'attachment.txt');
    expect(openFileName(file('Kühlschrank', 'text/plain')), 'Kühlschrank.txt');
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

    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(mode(), ThemeMode.light);
    expect(storage.theme, 'light');

    // Teal, or the logo's orange, light and dark.
    Color primary() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .colorScheme
        .primary;
    final teal = primary();
    await tester.tap(find.text('Orange'));
    await tester.pumpAndSettle();
    expect(storage.colour, 'orange');
    expect(primary(), isNot(teal));
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

    await tester.tap(find.text('Garage/Shelf 1'));
    await tester.pumpAndSettle();
    expect(find.text('Quantity'), findsOneWidget);

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
    await tester.enterText(field('Quantity (pieces)'), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    expect(
      fake.changes.last,
      endsWith('/move {"location":"l-shelf2","quantity":1}'),
    );
    // The row at the destination.
    expect(find.text('Garage/Shelf 2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
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

    // A class brings its attributes.
    await tester.tap(find.text('Any class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    expect(field('Voltage'), findsOneWidget);

    // A condition that doesn't parse stays on the form.
    await tester.enterText(field('Voltage'), '>= 3 kg');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('unknown unit "kg"'), findsOneWidget);
    expect(find.byType(FoundItemsScreen), findsNothing);

    // In any unit of the quantity: 12000 mV is 12 V.
    await tester.enterText(field('Voltage'), '>= 12000mV');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(fake.lastWhere, '[{"attribute":"a-volt","op":">=","value":12}]');
    expect(find.text('1 item found'), findsOneWidget);
    // A table, with a column for each attribute the items show.
    expect(find.text('Where'), findsOneWidget);
    expect(find.text('Voltage'), findsOneWidget);
    expect(find.text('Cordless drill'), findsOneWidget);
    expect(find.text('18 V'), findsOneWidget);
    expect(find.text('Garage/Shelf 1'), findsOneWidget);
    // A long value can't make its row tall: cells end after three lines.
    expect(tester.widget<Text>(find.text('18 V')).maxLines, 3);
    expect(tester.widget<Text>(find.text('Garage/Shelf 1')).maxLines, 3);

    // Back to the form, as it was filled in.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('Voltage')).controller!.text,
      '>= 12000mV',
    );
    expect(find.text('Tools/Drills'), findsOneWidget);

    await tester.enterText(field('Voltage'), '20..24');
    await tester.tap(find.widgetWithText(FilledButton, 'Search'));
    await tester.pumpAndSettle();
    expect(
      fake.lastWhere,
      '[{"attribute":"a-volt","op":"between","value":[20,24]}]',
    );
    expect(find.text('Nothing found.'), findsOneWidget);
  });

  testWidgets('a URL value is a link: open it, or copy it from its menu', (
    tester,
  ) async {
    setSize(tester, 400);
    final fake = FakeServer();
    const url = 'https://example.com/drill.pdf';
    (fake.items.first['values'] as Map)['a-manual'] = url;
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
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();

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
    setSize(tester, 1200);
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
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    router.push('/classes/c-drills');
    await tester.pumpAndSettle();
    // No empty section for the stock rows' attributes.
    expect(find.text('Item attributes'), findsOneWidget);
    expect(find.text('Stock attributes'), findsNothing);
    expect(find.text('Attributes'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Assign'), findsOneWidget);

    fake.voltagePerUnit = true;
    await tester.pageBack();
    await tester.pumpAndSettle();
    router.push('/classes/c-drills');
    await tester.pumpAndSettle();
    expect(find.text('Item attributes'), findsNothing);
    expect(find.text('Stock attributes'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Assign'), findsOneWidget);

    // A class without attributes: only the heading that holds Assign.
    await tester.pageBack();
    await tester.pumpAndSettle();
    router.push('/classes/c-tools');
    await tester.pumpAndSettle();
    expect(find.text('Attributes'), findsOneWidget);
    expect(find.text('Item attributes'), findsNothing);
    expect(find.text('Stock attributes'), findsNothing);
  });

  testWidgets('assigning an attribute asks for its default, not its name', (
    tester,
  ) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer());
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .push('/classes/c-drills');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voltage *'));
    await tester.pumpAndSettle();
    expect(find.text('Voltage in Drills'), findsOneWidget);
    expect(field('Default value *'), findsNothing);
    expect(field('Default value'), findsOneWidget);
    expect(field('Voltage'), findsNothing);
    expect(find.textContaining('Empty: no default'), findsOneWidget);
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

  testWidgets('a label code finds its object', (tester) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer());
    await search(tester, '1a-01'); // case and hyphens don't matter
    expect(find.text('Label code: Location 1A01'), findsOneWidget);
    await tester.tap(find.text('Garage/Shelf 1'));
    await tester.pumpAndSettle();
    expect(find.text('Stock here'), findsOneWidget);
    expect(find.text('Cordless drill'), findsOneWidget);
  });

  testWidgets('add an item with a value in other units, without stock', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
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

    // A required value, checked with the units of its quantity.
    expect(field('Voltage *'), findsOneWidget);
    await tester.enterText(field('Name'), 'Impact driver');
    await tester.enterText(field('Voltage *'), '3 kg');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('unknown unit "kg"'), findsOneWidget);
    expect(fake.changes, isEmpty);

    // A plain number is in the unit picked next to the field: the
    // attribute's own (V) until another of its family is chosen.
    await tester.tap(find.text('V'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mV').last);
    await tester.pumpAndSettle();
    await tester.enterText(field('Voltage *'), '18000');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.single,
      'POST /api/v1/items {"class":"c-drills","name":"Impact driver","values":{"a-volt":18}}',
    );

    // Asked once, as in the CLI.
    expect(find.text('Add stock for Impact driver?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Impact driver'), findsWidgets);
    expect(find.text('No stock.'), findsOneWidget);
  });

  testWidgets('add an item, then its stock', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await tester.tap(find.text('New item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools/Drills'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Hammer drill');
    await tester.enterText(field('Voltage *'), '230');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add stock'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose a location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Garage/Shelf 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // Uncounted (empty quantity); then the item's screen shows it.
    expect(fake.changes.last, contains('"location":"l-shelf2"}'));
    expect(find.text('Hammer drill'), findsWidgets);
    expect(find.text('uncounted'), findsOneWidget);
  });

  testWidgets('the location tree, and a box with compartments', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    final shelf = fake.locations.firstWhere((l) => l['name'] == 'Shelf 1');
    shelf['photo'] = {
      'id': 'att-shelf',
      'title': 'Shelf',
      'type': 'image/png',
      'size': 3,
      'hash': 'ab',
    };
    await startApp(tester, fake);

    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    expect(find.text('Garage/'), findsOneWidget);
    expect(find.text('Shelf 1'), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('Shelf 1'), findsOneWidget);

    // The tree shows a location's photo small, and its icon, framed the
    // same, when it has none.
    expect(find.byType(Thumbnail), findsOneWidget);
    final photo = tester.widget<Thumbnail>(find.byType(Thumbnail));
    expect(photo.attachment.owner, '/locations/${shelf['id']}');
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
      'POST /api/v1/locations {"name":"Box","grid":{"columns":2,"rows":3}}',
    );
    expect(find.text('Container'), findsOneWidget);
    expect(find.text('B3'), findsOneWidget);
    // The tree underneath already shows the new box.
    expect(find.text('Box/', skipOffstage: false), findsOneWidget);
  });

  testWidgets('edit an item: rename it, change a value, then clear it', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    await startApp(tester, fake);
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    // The current value as shown: the number in the field, its unit in the
    // menu. It reads back unchanged.
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
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.changes, [
      'PATCH /api/v1/items/i-drill {"name":"Old drill"}',
      'PUT /api/v1/items/i-drill/values/a-volt {"value":14.4}',
    ]);
    expect(find.text('14.4 V'), findsOneWidget);

    // A value shown in another unit of the family opens in that unit.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Voltage *'), '0.5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      fake.changes.last,
      'PUT /api/v1/items/i-drill/values/a-volt {"value":0.5}',
    );
    expect(find.text('500 mV'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('Voltage *')).controller!.text,
      '500',
    );
    expect(
      find.descendant(of: field('Voltage *'), matching: find.text('mV')),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.changes, hasLength(3));
    expect(find.text('No changes.'), findsOneWidget);

    // A required value without a default can't be cleared.
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Voltage *'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(fake.changes, hasLength(3));
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

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete location Garage?'), findsOneWidget);
    expect(find.text('And the 2 locations below it:'), findsOneWidget);
    expect(find.text('1 stock row is in them:'), findsOneWidget);
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
    // Marked deleted, not removed (api/deleting.md).
    expect(fake.locations.every((l) => l['deleted'] == true), isTrue);
    expect(fake.stock.every((s) => s['deleted'] == true), isTrue);
  });

  testWidgets('read-only accounts get no buttons that would be refused', (
    tester,
  ) async {
    setSize(tester, 1000);
    await startApp(tester, FakeServer(privilege: 'read_only'));
    expect(find.text('New item'), findsNothing);
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    expect(find.text('Add stock'), findsNothing);
    expect(find.byTooltip('Edit'), findsNothing);
  });
}
