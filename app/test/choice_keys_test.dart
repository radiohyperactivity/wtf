import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/api/models.dart';
import 'package:wtf/widgets/value_fields.dart';

void main() {
  testWidgets('a choice value: typing narrows the options, Enter takes one', (
    tester,
  ) async {
    final input = ValueInput(
      attribute: Attribute(
        id: 'a',
        name: 'Package',
        datatype: 'choice',
        options: [
          for (final n in ['DIP', 'SOIC', 'SSOP', 'QFN'])
            NamedRef.fromJson({'id': n, 'name': n}),
        ],
      ),
      defaultText: 'DIP',
    );
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Form(child: ValueField(input))),
      ),
    );
    final field = find.byType(TextField);

    // Lower case finds the option, and only those with it are offered.
    await tester.enterText(field, 's');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'SOIC'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'SSOP'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'DIP'), findsNothing);
    await tester.enterText(field, 'so');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(input.text, 'SOIC');

    // The empty entry clears it, so the default applies.
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(find.text('— (DIP)'), findsOneWidget);
    await tester.tap(find.text('— (DIP)'));
    await tester.pumpAndSettle();
    expect(input.text, '');
    expect(input.validate(), isNull);

    // What isn't an option is refused.
    await tester.enterText(field, 'TO-92');
    await tester.pumpAndSettle();
    expect(input.validate(), isNotNull);
  });
}
