// Inputs for attribute values: a text field that understands dates ("+2w")
// and yes/no as the CLI does, or a list for choices and yes/no. A number's
// unit is a label after it; nothing converts.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api/input.dart';
import '../api/models.dart';

/// A value as it is typed in: a number without its unit, yes/no, the rest
/// as it is.
String inputText(Object? v) => switch (v) {
  null => '',
  bool b => b ? 'yes' : 'no',
  num n => formatNumber(n),
  _ => '$v',
};

/// One attribute in a form: its value as typed, and whether it is to
/// follow the class's default again.
class ValueInput {
  ValueInput({
    required this.attribute,
    Object? current,
    this.followsDefault = false,
  }) : initial = inputText(current),
       controller = TextEditingController(text: inputText(current)) {
    controller.addListener(() {
      // Typing a value of its own leaves the default.
      if (backToDefault && text != attribute.defaultText.trim()) {
        backToDefault = false;
      }
    });
  }

  final Attribute attribute;

  /// The value when the form opened, as text.
  final String initial;

  /// Whether the value followed the class's default when the form opened.
  final bool followsDefault;

  /// "Back to the default" was chosen.
  bool backToDefault = false;
  final TextEditingController controller;

  String get text => controller.text.trim();

  /// Whether the value differs from when the form opened.
  bool get changed => backToDefault ? !followsDefault : text != initial.trim();

  /// Whether "Back to the default" makes sense: there is a default, and the
  /// value doesn't follow it (or no longer does, typed over).
  bool get canGoBack =>
      attribute.defaultValue != null &&
      !backToDefault &&
      (!followsDefault || text != initial.trim());

  void goBack() {
    controller.text = attribute.defaultText;
    backToDefault = true;
  }

  /// The value for the API; null when empty.
  Object? parse() => text.isEmpty ? null : parseValue(attribute, text);

  String? validate() {
    if (backToDefault) return null;
    if (text.isEmpty) {
      return attribute.required && attribute.defaultValue == null
          ? 'Required'
          : null;
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

/// The inputs for a class's attributes of one scope: the item's ([stock]
/// false) or a stock row's, in the class's order. Files are uploaded
/// instead, so attachments have none. [values] and [defaulted] are the
/// row's, when editing.
List<ValueInput> valueInputs(
  ClassDetail cls, {
  required bool stock,
  Values values = const {},
  Set<String> defaulted = const {},
}) => [
  for (final a in cls.scoped(stock: stock))
    if (!a.isFile)
      ValueInput(
        attribute: a,
        current: values[a.name],
        followsDefault: defaulted.contains(a.name),
      ),
];

/// What a form's inputs change, for a PATCH: `values`, by name (null
/// removes one), and `default`, the names to give their default back.
Json valueChanges(List<ValueInput> inputs) {
  final values = <String, Object?>{};
  final defaults = <String>[];
  for (final i in inputs.where((i) => i.changed)) {
    if (i.backToDefault) {
      defaults.add(i.attribute.name);
    } else {
      values[i.attribute.name] = i.parse();
    }
  }
  return {
    if (values.isNotEmpty) 'values': values,
    if (defaults.isNotEmpty) 'default': defaults,
  };
}

/// The values typed into a new item's or stock row's form, by name; those
/// left empty get their defaults.
Values newValues(List<ValueInput> inputs) => {
  for (final i in inputs)
    if (i.text.isNotEmpty) i.attribute.name: i.parse(),
};

/// The input for one attribute, labelled with its name unless [label] says
/// otherwise.
class ValueField extends StatefulWidget {
  const ValueField(this.input, {super.key, this.label, this.helper});

  final ValueInput input;
  final String? label;

  /// Under the field; a date's format comes first.
  final String? helper;

  @override
  State<ValueField> createState() => _ValueFieldState();
}

class _ValueFieldState extends State<ValueField> {
  ValueInput get input => widget.input;

  String get _label {
    final name = widget.label ?? input.attribute.name;
    return input.attribute.required ? '$name *' : name;
  }

  String? get _hint {
    final d = input.attribute.defaultText;
    return d.isEmpty ? null : 'Default: $d';
  }

  /// Says whether the value follows the class's default.
  String? get _helper {
    final follows =
        input.backToDefault || input.followsDefault && !input.changed;
    final parts = [if (follows) "The class's default", ?widget.helper];
    return parts.isEmpty ? null : parts.join('. ');
  }

  @override
  void initState() {
    super.initState();
    input.controller.addListener(_changed);
  }

  @override
  void dispose() {
    input.controller.removeListener(_changed);
    super.dispose();
  }

  /// The text changed: whether the value follows the default may have too.
  /// A choice's menu sets its text while it builds, when this can only
  /// build again after the frame.
  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Widget? get _backButton => input.canGoBack
      ? IconButton(
          icon: const Icon(Icons.settings_backup_restore),
          tooltip: 'Back to the default (${input.attribute.defaultText})',
          onPressed: () => setState(input.goBack),
        )
      : null;

  @override
  Widget build(BuildContext context) {
    final a = input.attribute;
    final decoration = InputDecoration(
      labelText: _label,
      hintText: _hint,
      helperText: _helper,
      helperMaxLines: 3,
      suffixText: a.unit,
      suffixIcon: _backButton,
      border: const OutlineInputBorder(),
    );
    switch (a.type) {
      case 'choice' || 'boolean':
        final options = a.type == 'boolean' ? const ['yes', 'no'] : a.choices;
        // The current text, matched to an option ignoring case.
        final current =
            options
                .where((o) => o.toLowerCase() == input.text.toLowerCase())
                .firstOrNull ??
            '';
        // Typed into, it narrows the list to the options with what was
        // typed, open or not; the arrows and Enter choose. The text is the
        // value: what isn't an option is refused when saving.
        return Row(
          children: [
            Expanded(
              child: DropdownMenuFormField<String>(
                // Rebuilt when "Back to the default" sets the text.
                key: ValueKey((a.name, input.backToDefault)),
                controller: input.controller,
                initialSelection: current,
                enableFilter: true,
                // Typing everywhere, also on phones, where it is off by
                // default.
                requestFocusOnTap: true,
                expandedInsets: EdgeInsets.zero,
                label: Text(_label),
                hintText: _hint,
                helperText: _helper,
                inputDecorationTheme: const InputDecorationTheme(
                  border: OutlineInputBorder(),
                ),
                dropdownMenuEntries: [
                  // No value: the default, if any, is given.
                  DropdownMenuEntry(
                    value: '',
                    label: '',
                    labelWidget: Text(
                      a.defaultText.isEmpty ? '—' : '— (${a.defaultText})',
                    ),
                  ),
                  for (final o in options)
                    DropdownMenuEntry(value: o, label: o),
                ],
                validator: (_) => input.validate(),
              ),
            ),
            ?_backButton,
          ],
        );
      case 'date':
        return TextFormField(
          controller: input.controller,
          decoration: decoration.copyWith(
            helperText: [
              'YYYY-MM-DD, today, +3d, -2w, +1m …',
              ?_helper,
            ].join('. '),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?_backButton,
                IconButton(
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
                    if (d != null) input.controller.text = formatDate(d);
                  },
                ),
              ],
            ),
          ),
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (_) => input.validate(),
        );
      default:
        return TextFormField(
          controller: input.controller,
          decoration: decoration,
          keyboardType: switch (a.type) {
            'url' => TextInputType.url,
            'integer' || 'decimal' => const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            _ => null,
          },
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (_) => input.validate(),
        );
    }
  }
}

/// An amount field: empty means uncounted (or, when moving or merging, all
/// of it). [unit] is the item's: what its stock is counted in, a label
/// (null: pieces, integers).
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.unit,
    this.emptyMeans = 'uncounted',
  });

  final TextEditingController controller;
  final String? unit;
  final String emptyMeans;

  /// The amount for the API; null when empty.
  static Decimal? parse(TextEditingController controller, String? unit) =>
      controller.text.trim().isEmpty
      ? null
      : parseNumber(controller.text, unit: unit, integer: unit == null);

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    decoration: InputDecoration(
      labelText: 'Amount',
      suffixText: unit ?? 'pieces',
      helperText: 'Empty: $emptyMeans',
      border: const OutlineInputBorder(),
    ),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: (_) {
      try {
        parse(controller, unit);
        return null;
      } on InputError catch (e) {
        return e.message;
      }
    },
  );
}
