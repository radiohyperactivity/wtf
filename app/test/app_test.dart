import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/app.dart';
import 'package:wtf/screens/search_screen.dart';
import 'package:wtf/session.dart';

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
    const length = {'id': 1000, 'name': 'Length', 'datatype': 'float'};
    Map<String, dynamic> family(
      int id,
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
      family(1000, 'Metric length', [
        [1002, 'millimetre', 'mm', 0.001],
        [1004, 'metre', 'm', 1],
      ]),
      family(1001, 'Imperial length', [
        [1007, 'inch', 'in', 0.0254],
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

    // The next start.
    final next = Session(storage: storage, httpClient: fake.client);
    await next.restore();
    expect(next.themeMode, ThemeMode.light);
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
    await startApp(tester, fake);

    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    expect(find.text('Garage/'), findsOneWidget);
    expect(find.text('Shelf 1'), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('Shelf 1'), findsOneWidget);

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
