// Deleted things and history in words (api/deleting.md, history_text.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/api/client.dart';
import 'package:wtf/api/history_text.dart';
import 'package:wtf/api/models.dart';
import 'package:wtf/api/units.dart';

import 'app_test.dart' show search, setSize, startApp;
import 'fake_server.dart';

var _ids = 1000;

Unit unit(String symbol, String factor) => Unit(
  id: _ids++,
  name: symbol,
  symbol: symbol,
  familyId: 1000,
  familyName: 'Metric length',
  quantity: const Quantity(id: 1000, name: 'Length', datatype: 'float'),
  baseFactor: Rational.tryParse(factor)!,
  baseOffset: Rational(BigInt.zero),
);

/// A history entry as the server sends it.
Map<String, dynamic> entry(
  int id,
  String transaction,
  String table,
  String operation,
  Map<String, dynamic> data, [
  Map<String, dynamic> changes = const {},
]) => {
  'id': id,
  'happened_at': '2026-10-27T10:0$id:00Z',
  'transaction': transaction,
  'account': {'id': 'a1', 'email': 'anna@example.com', 'deleted': false},
  'table': table,
  'operation': operation,
  'data': data,
  'changes': changes.isEmpty ? null : changes,
};

void main() {
  test('numbers in their best unit, as the server shows them', () {
    final metres = [unit('mm', '0.001'), unit('m', '1'), unit('km', '1000')];
    final mm = metres.first;
    String show(String base, {bool lock = false}) =>
        displayIn(Rational.tryParse(base)!, mm, metres, lock: lock);
    expect(show('0.0012'), '1.2 mm');
    expect(show('12'), '12 m');
    expect(show('2500'), '2.5 km');
    expect(show('0'), '0 mm'); // in the unit itself
    expect(show('0.0000005'), '0.0005 mm'); // smaller than every unit
    // Unit lock: always in the unit itself.
    expect(show('2500', lock: true), '2500000 mm');
    expect(Rational.tryParse('1')! / Rational.tryParse('3')!, isA<Rational>());
    expect(
      (Rational.tryParse('1')! / Rational.tryParse('3')!).toDecimal(6),
      '0.333333',
    );
  });

  test('label codes from code numbers', () {
    expect(codeText(32768), '1000');
    expect(codeText(0), '0');
    expect(codeText(32 * 32 * 32 + 10 * 32 * 32 + 7 * 32 + 20), '1A7M');
  });

  test('history in words, with names and units', () async {
    final fake = FakeServer();
    final client = ApiClient(
      Uri.parse('http://wtf.test:8080'),
      httpClient: fake.client,
      manageCookie: true,
      session: 'tok',
    );
    final entries = [
      entry(
        6,
        't4',
        'location',
        'update',
        {
          'id': 'l-shelf2',
          'name': 'Shelf 2',
          'parent': 'l-garage',
          'code': 32768,
          'deleted': true,
        },
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
      entry(
        5,
        't3',
        'value',
        'update',
        {'item': 'i-drill', 'attribute': 'a-volt', 'float_value': 18},
        {
          'float_value': {'old': 12, 'new': 18},
        },
      ),
      entry(4, 't2', 'stock', 'insert', {
        'id': 's-2',
        'code': 1645,
        'item': 'i-drill',
        'location': 'l-shelf2',
        'quantity': 1,
      }),
      entry(
        3,
        't2',
        'stock',
        'update',
        {
          'id': 's-1',
          'code': 1000,
          'item': 'i-drill',
          'location': 'l-shelf1',
          'quantity': 2,
        },
        {
          'quantity': {'old': 3, 'new': 2},
        },
      ),
      entry(1, 't1', 'item', 'insert', {
        'id': 'i-drill',
        'code': 1100,
        'name': 'Cordless drill',
        'class': 'c-drills',
      }),
    ].map(HistoryEntry.fromJson).toList();

    final names = HistoryNames(client);
    await names.load(entries);
    final item = historyEvents(
      entries,
      names,
      const HistoryFocus('items', 'i-drill'),
    );
    expect(item.map((e) => e.lines.map((l) => l.text).join('; ')), [
      'Deleted location Shelf 2',
      'Voltage: 12 V → 18 V',
      'Moved 1 from Garage/Shelf 1 to Garage/Shelf 2, into a new row ${codeText(1645)}',
      'Created in Tools/Drills',
    ]);
    expect(item[2].lines.single.link, '/stock/${codeText(1645)}');

    // The same move, in the history of a location: named by item.
    final shelf = historyEvents(
      entries.where((e) => e.table == 'stock').toList(),
      names,
      const HistoryFocus('locations', 'l-shelf1'),
    );
    expect(
      shelf.single.lines.single.text,
      'Moved 1 of Cordless drill from Garage/Shelf 1 to Garage/Shelf 2, into a new row ${codeText(1645)}',
    );

    // A box deleted with what was inside it is one line.
    final box = [
      entry(
        9,
        't9',
        'stock',
        'update',
        {
          'id': 's-1',
          'code': 1000,
          'item': 'i-drill',
          'location': 'l-a1',
          'quantity': 2,
          'deleted': true,
        },
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
      entry(
        8,
        't9',
        'location',
        'update',
        {
          'id': 'l-a1',
          'name': 'A1',
          'parent': 'l-box',
          'code': 40000,
          'deleted': true,
        },
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
      entry(
        7,
        't9',
        'location',
        'update',
        {
          'id': 'l-box',
          'name': 'Box',
          'parent': 'l-shelf1',
          'code': 40001,
          'deleted': true,
        },
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
    ].map(HistoryEntry.fromJson).toList();
    await names.load(box);
    final deleted = historyEvents(
      box,
      names,
      const HistoryFocus('locations', 'l-shelf1'),
    );
    expect(
      deleted.single.lines.single.text,
      'Deleted Box, with 1 location inside and 1 stock row',
    );
    expect(deleted.single.lines.single.link, '/locations/${codeText(40001)}');
  });

  testWidgets(
    'a deleted location shows it, and is restored with what it is in',
    (tester) async {
      setSize(tester, 1000);
      final fake = FakeServer();
      for (final l in fake.locations) {
        if (l['id'] != 'l-shelf1') l['deleted'] = true;
      }
      fake.history['locations/l-shelf2'] = [
        entry(
          1,
          't',
          'location',
          'update',
          {
            'id': 'l-shelf2',
            'name': 'Shelf 2',
            'parent': 'l-garage',
            'deleted': true,
          },
          {
            'deleted': {'old': false, 'new': true},
          },
        ),
      ];
      await startApp(tester, fake);
      await search(tester, '1A02');
      expect(find.textContaining('Location 1A02, deleted'), findsOneWidget);
      await tester.tap(find.text('Garage/Shelf 2'));
      await tester.pumpAndSettle();

      expect(find.text('This location is deleted.'), findsOneWidget);
      expect(find.textContaining('by anna@example.com'), findsOneWidget);
      expect(find.text('Add stock here'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.textContaining('which is deleted'), findsOneWidget);
      await tester.tap(find.text('Restore the location too'));
      await tester.pumpAndSettle();
      expect(fake.changes, [
        'POST /api/v1/locations/l-shelf2/restore {}',
        'POST /api/v1/locations/l-shelf2/restore {"with_parents":true}',
      ]);
      expect(find.text('This location is deleted.'), findsNothing);
    },
  );

  testWidgets('the history screen tells what happened, by day', (tester) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    fake.history['items/i-drill'] = [
      entry(
        2,
        't2',
        'value',
        'update',
        {'item': 'i-drill', 'attribute': 'a-volt', 'float_value': 18},
        {
          'float_value': {'old': 12, 'new': 18},
        },
      ),
      entry(1, 't1', 'item', 'insert', {
        'id': 'i-drill',
        'code': 1100,
        'name': 'Cordless drill',
        'class': 'c-drills',
      }),
    ];
    await startApp(tester, fake);
    await search(tester, 'drill');
    await tester.tap(find.text('Cordless drill'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();

    expect(find.text('Voltage: 12 V → 18 V'), findsOneWidget);
    expect(find.text('Created in Tools/Drills'), findsOneWidget);
    expect(find.textContaining('anna@example.com'), findsNWidgets(2));
    // Tapping an action shows its raw entries.
    await tester.tap(find.text('Voltage: 12 V → 18 V'));
    await tester.pumpAndSettle();
    expect(find.textContaining('update value'), findsOneWidget);
  });

  testWidgets('the top level of a tree has a history, with deleted locations', (
    tester,
  ) async {
    setSize(tester, 1000);
    final fake = FakeServer();
    fake.history['locations'] = [
      entry(
        3,
        't3',
        'location',
        'update',
        {'id': 'l-shed', 'name': 'Shed', 'parent': null, 'deleted': true},
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
      entry(
        2,
        't2',
        'location',
        'update',
        {'id': 'l-shelf1', 'name': 'Shelf 1', 'parent': null},
        {
          'parent': {'old': 'l-garage', 'new': null},
        },
      ),
      entry(1, 't1', 'location', 'insert', {
        'id': 'l-garage',
        'name': 'Garage',
        'parent': null,
      }),
    ];
    await startApp(tester, fake);
    await tester.tap(find.text('Locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();

    expect(find.text('History of the top-level locations'), findsOneWidget);
    expect(find.text('Deleted location Shed'), findsOneWidget);
    expect(
      find.text('Location Shelf 1 moved to the top from Garage'),
      findsOneWidget,
    );
    expect(find.text('Added location Garage at the top'), findsOneWidget);
  });

  test('the history of all attributes names each attribute', () async {
    final fake = FakeServer();
    final client = ApiClient(
      Uri.parse('http://wtf.test:8080'),
      httpClient: fake.client,
      manageCookie: true,
      session: 'tok',
    );
    final entries = [
      entry(
        2,
        't2',
        'attribute',
        'update',
        {'id': 'a-size', 'name': 'Size', 'datatype': 'text', 'deleted': true},
        {
          'deleted': {'old': false, 'new': true},
        },
      ),
      entry(1, 't1', 'attribute', 'insert', {
        'id': 'a-size',
        'name': 'Size',
        'datatype': 'text',
      }),
    ].map(HistoryEntry.fromJson).toList();
    final names = HistoryNames(client);
    await names.load(entries);
    final lines = historyEvents(
      entries,
      names,
      const HistoryFocus('attributes'),
    ).map((e) => e.lines.single);
    expect(lines.map((l) => l.text), [
      'Deleted attribute Size',
      'Created attribute Size (text)',
    ]);
    expect(lines.first.link, '/attributes/a-size');
    // In the attribute's own history, it isn't named.
    expect(
      historyEvents(
        entries,
        names,
        const HistoryFocus('attributes', 'a-size'),
      ).map((e) => e.lines.single.text),
      ['Deleted', 'Created (Size, text)'],
    );
  });
}
