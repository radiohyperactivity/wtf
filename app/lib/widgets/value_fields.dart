// Inputs for attribute values: a text field that understands units
// ("12mm"), dates ("+2w") and yes/no as the CLI does, or a list for choices.
// A number field has a menu of its unit's family next to it, for numbers
// typed without a unit.

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';

/// One attribute in a form, with what checking its input needs.
class ValueInput {
  ValueInput({
    required this.attribute,
    this.required = false,
    this.defaultText = '',
    String initial = '',
    this.units,
  }) : controller = MeasureController(plainIn: units?.unit) {
    controller.show(initial, units);
    this.initial = controller.text;
    initialUnit = controller.plainIn;
  }

  /// With its options, for a choice attribute.
  final Attribute attribute;
  final bool required;

  /// The class default, which applies while there's no own value.
  final String defaultText;

  /// The own value as text, when editing; a number without the unit, which
  /// is [initialUnit].
  late final String initial;
  late final Unit? initialUnit;

  /// For numbers with a unit.
  final UnitChoice? units;
  final MeasureController controller;

  String get text => controller.text.trim();
  bool get changed =>
      text != initial.trim() ||
      (text.isNotEmpty && controller.plainIn?.id != initialUnit?.id);

  /// The value for the API; null when empty.
  Object? parse() => text.isEmpty
      ? null
      : parseValue(attribute, text, units, controller.plainIn);

  String? validate() {
    if (text.isEmpty) {
      return required && defaultText.isEmpty ? 'Required' : null;
    }
    try {
      parse();
      return null;
    } on InputError catch (e) {
      // The field's label names the attribute already.
      final prefix = '${attribute.name}: ';
      return e.message.startsWith(prefix)
          ? e.message.substring(prefix.length)
          : e.message;
    }
  }

  void dispose() => controller.dispose();
}

/// The inputs for a class's attributes: the item's own ([perUnit] false)
/// or the stock rows' ([perUnit] true), required ones first. [current] are
/// the own values, by attribute id.
Future<List<ValueInput>> loadValueInputs(
  ApiClient client,
  List<ClassAttribute> attributes, {
  required bool perUnit,
  Map<String, String> current = const {},
}) async {
  final chosen = attributes.where((a) => a.perUnit == perUnit).toList();
  final ordered = [
    ...chosen.where((a) => a.required),
    ...chosen.where((a) => !a.required),
  ];
  return Future.wait(
    ordered.map((ca) async {
      final attribute = ca.attribute.datatype == 'choice'
          ? await client.attribute(ca.attribute.id)
          : ca.attribute;
      final unit = attribute.unit;
      return ValueInput(
        attribute: attribute,
        required: ca.required,
        defaultText: ca.defaultText,
        initial: current[ca.attribute.id] ?? '',
        units: unit == null ? null : await client.unitChoice(unit),
      );
    }),
  );
}

/// The own values of an item or a stock row, as text, by attribute id.
Map<String, String> ownValues(List<Value> values) => {
  for (final v in values)
    if (!v.isDefault) v.attribute.id: v.text,
};

/// The input for one attribute.
class ValueField extends StatefulWidget {
  const ValueField(this.input, {super.key});

  final ValueInput input;

  @override
  State<ValueField> createState() => _ValueFieldState();
}

class _ValueFieldState extends State<ValueField> {
  ValueInput get input => widget.input;

  String get _label =>
      input.required ? '${input.attribute.name} *' : input.attribute.name;

  String? get _hint {
    if (input.defaultText.isNotEmpty) return 'Default: ${input.defaultText}';
    final units = input.units;
    return units == null ? null : measureHint(units, input.controller);
  }

  @override
  Widget build(BuildContext context) {
    final a = input.attribute;
    final decoration = InputDecoration(
      labelText: _label,
      hintText: _hint,
      border: const OutlineInputBorder(),
    );
    switch (a.datatype) {
      case 'choice' || 'boolean':
        final options = a.datatype == 'boolean'
            ? const ['yes', 'no']
            : a.options.map((o) => o.name).toList();
        // The current text, matched to an option ignoring case.
        final current =
            options
                .where((o) => o.toLowerCase() == input.text.toLowerCase())
                .firstOrNull ??
            '';
        return DropdownButtonFormField<String>(
          initialValue: current,
          decoration: decoration.copyWith(hintText: null, helperText: _hint),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                input.defaultText.isEmpty ? '—' : '— (${input.defaultText})',
              ),
            ),
            for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (v) => input.controller.text = v ?? '',
          validator: (_) => input.validate(),
        );
      case 'date':
        return TextFormField(
          controller: input.controller,
          decoration: decoration.copyWith(
            helperText: 'YYYY-MM-DD, today, +3d, -2w, +1m …',
            suffixIcon: IconButton(
              icon: const Icon(Icons.calendar_today),
              tooltip: 'Choose a date',
              onPressed: () async {
                DateTime? initial;
                try {
                  initial = DateTime.parse(parseDate(input.text));
                } on Object {
                  initial = null;
                }
                final d = await showDatePicker(
                  context: context,
                  initialDate: initial ?? DateTime.now(),
                  firstDate: DateTime(1900),
                  lastDate: DateTime(2200),
                );
                if (d != null) {
                  input.controller.text =
                      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                }
              },
            ),
          ),
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (_) => input.validate(),
        );
      default:
        final units = input.units;
        return TextFormField(
          controller: input.controller,
          decoration: units == null
              ? decoration
              : decoration.copyWith(
                  suffixIcon: UnitMenu(
                    units: units,
                    controller: input.controller,
                    onChanged: () => setState(() {}),
                  ),
                ),
          keyboardType: a.datatype == 'url' ? TextInputType.url : null,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (_) => input.validate(),
        );
    }
  }
}

/// The text of a number field, and the unit picked in its [UnitMenu]: a
/// number typed without a unit is in [plainIn].
class MeasureController extends TextEditingController {
  MeasureController({super.text, this.plainIn});

  Unit? plainIn;

  /// Shows [shown], a number as the server shows it ("64 kHz"): the number
  /// in the field and its unit in the menu, when the unit is in the menu.
  /// Anything else goes in the field as it is.
  void show(String shown, UnitChoice? units) {
    text = shown;
    final split = splitShown(shown);
    if (units == null || split == null || split.$2.isEmpty) return;
    final (number, symbol) = split;
    for (final u in units.familyUnits) {
      if (u.symbol == symbol) {
        text = number;
        plainIn = u;
        return;
      }
    }
  }
}

/// A hint for a number field: "e.g. 12, or 1.5 m".
String measureHint(UnitChoice units, MeasureController controller) {
  final picked = controller.plainIn ?? units.unit;
  final other =
      units.familyUnits.where((u) => u.symbol != picked.symbol).lastOrNull ??
      units.quantityUnits.where((u) => u.symbol != picked.symbol).firstOrNull;
  return other == null ? 'e.g. 12' : 'e.g. 12, or 1.5 ${other.symbol}';
}

/// The units of a number's family, next to its field: the unit a number
/// typed without one is in. It starts at the attribute's or item's own unit;
/// a number typed with a unit ("1in") ignores it.
class UnitMenu extends StatelessWidget {
  const UnitMenu({
    super.key,
    required this.units,
    required this.controller,
    this.onChanged,
  });

  final UnitChoice units;
  final MeasureController controller;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final picked = controller.plainIn ?? units.unit;
    final family = units.familyUnits.isEmpty ? [units.unit] : units.familyUnits;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: picked.id,
          isDense: true,
          items: [
            for (final u in family)
              DropdownMenuItem(value: u.id, child: Text(u.symbol)),
          ],
          onChanged: family.length < 2
              ? null
              : (id) {
                  controller.plainIn = family.firstWhere((u) => u.id == id);
                  onChanged?.call();
                },
        ),
      ),
    );
  }
}

/// A quantity field: empty means uncounted (or, when moving, all of it).
/// Numbers may carry units of the item's unit's quantity, as in the CLI.
class QuantityField extends StatefulWidget {
  const QuantityField({
    super.key,
    required this.controller,
    this.units,
    this.emptyMeans = 'uncounted',
  });

  final MeasureController controller;
  final UnitChoice? units;
  final String emptyMeans;

  /// The quantity for the API; null when empty.
  static Decimal? parse(MeasureController controller, UnitChoice? units) =>
      controller.text.trim().isEmpty
      ? null
      : parseMeasure(controller.text, units, plainIn: controller.plainIn);

  @override
  State<QuantityField> createState() => _QuantityFieldState();
}

class _QuantityFieldState extends State<QuantityField> {
  @override
  Widget build(BuildContext context) {
    final units = widget.units;
    final controller = widget.controller;
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: units == null
            ? 'Quantity (pieces)'
            : 'Quantity (${units.unit.familyName})',
        hintText: units == null ? null : measureHint(units, controller),
        helperText: 'Empty: ${widget.emptyMeans}',
        border: const OutlineInputBorder(),
        suffixIcon: units == null
            ? null
            : UnitMenu(
                units: units,
                controller: controller,
                onChanged: () => setState(() {}),
              ),
      ),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) {
        try {
          QuantityField.parse(controller, units);
          return null;
        } on InputError catch (e) {
          return e.message;
        }
      },
    );
  }
}

/// Unit lock for an attribute or item: numbers always shown in [unit]
/// itself, instead of in the unit of its family that scales best.
class UnitLockSwitch extends StatelessWidget {
  const UnitLockSwitch({
    super.key,
    required this.unit,
    required this.value,
    required this.onChanged,
  });

  final Unit unit;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('Unit lock'),
    subtitle: Text(
      value
          ? 'Always shown in ${unit.symbol}'
          : 'Shown in the unit of ${unit.familyName} that fits best',
    ),
    value: value,
    onChanged: onChanged,
  );
}

/// Saves the values of [inputs] that changed: [set] for new text, [remove]
/// for cleared text. Returns the names saved; on an error, it throws a
/// [PartialSave] that says what was already saved.
Future<List<String>> saveValues(
  List<ValueInput> inputs, {
  required Future<void> Function(String attributeId, Object value) set,
  required Future<void> Function(String attributeId) remove,
  List<String> savedBefore = const [],
}) async {
  final saved = [...savedBefore];
  for (final input in inputs.where((i) => i.changed)) {
    try {
      final value = input.parse();
      if (value == null) {
        await remove(input.attribute.id);
      } else {
        await set(input.attribute.id, value);
      }
      saved.add(input.attribute.name);
    } catch (e) {
      throw PartialSave(e, saved);
    }
  }
  return saved;
}

/// A save that failed halfway: [saved] were saved before [error].
class PartialSave implements Exception {
  const PartialSave(this.error, this.saved);

  final Object error;
  final List<String> saved;

  @override
  String toString() {
    final message = error is ApiProblem
        ? (error as ApiProblem).message
        : '$error';
    return saved.isEmpty
        ? message
        : '$message\nAlready saved: ${saved.join(', ')}';
  }
}
