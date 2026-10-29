// Keyboard choosing for dropdowns, as select boxes have it in browsers and
// desktop apps. Flutter's own dropdown only opens with Enter or space.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keys for the closed dropdown [child]: typing picks the next option whose
/// label starts with what was typed (letters typed within a second of each
/// other add up, as in "in" for integer; one letter again goes on to the
/// next option with it), and the up and down arrows pick the previous and
/// next option, instead of moving to another field. Enter and space still
/// open the menu.
class SelectKeys<T> extends StatefulWidget {
  const SelectKeys({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.child,
  });

  /// Each option's value and the label it is found by, in the menu's order.
  final List<(T, String)> options;
  final T? value;

  /// Null when the dropdown can't be changed.
  final ValueChanged<T>? onChanged;
  final Widget child;

  @override
  State<SelectKeys<T>> createState() => _SelectKeysState<T>();
}

class _SelectKeysState<T> extends State<SelectKeys<T>> {
  String _typed = '';
  DateTime _last = DateTime(0);

  // The option last picked, until the new value comes back: keys pressed
  // before the dropdown is built again go on from it.
  (T,)? _picked;

  @override
  void didUpdateWidget(SelectKeys<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _picked = null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final onChanged = widget.onChanged;
    final options = widget.options;
    if (onChanged == null || options.isEmpty) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final value = _picked == null ? widget.value : _picked!.$1;
    final current = options.indexWhere((o) => o.$1 == value);
    void pick(int i) {
      if (i == current) return;
      _picked = (options[i].$1,);
      onChanged(options[i].$1);
    }

    if (event.logicalKey
        case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowUp) {
      _typed = ''; // what is typed next starts afresh
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        pick(current < 0 ? 0 : (current + 1).clamp(0, options.length - 1));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        pick(current < 0 ? 0 : (current - 1).clamp(0, options.length - 1));
        return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    final char = event.character;
    if (char == null ||
        char.trim().isEmpty ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored; // space opens the menu
    }
    final now = DateTime.now();
    final more =
        _typed.isNotEmpty && now.difference(_last) < const Duration(seconds: 1);
    _last = now;
    _typed = more ? _typed + char.toLowerCase() : char.toLowerCase();
    // One letter typed again goes on to the next option with it; more
    // letters look from the current option on.
    final again = _typed.split('').every((c) => c == _typed[0]);
    final prefix = again ? _typed[0] : _typed;
    final from = again ? 1 : 0;
    for (var k = from; k < options.length + from; k++) {
      final i = (current < 0 ? k - from : current + k) % options.length;
      if (options[i].$2.toLowerCase().startsWith(prefix)) {
        pick(i);
        break;
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}

/// Keys for a field that opens a picker (a class, a location, a unit…):
/// typing opens it with what was typed in its search, and the down arrow
/// opens it, as a select box opens its list. Enter and space open it
/// already, as for any button.
class PickerKeys extends StatelessWidget {
  const PickerKeys({super.key, required this.open, required this.child});

  /// Opens the picker, searching for the text given; null when the field
  /// can't be changed.
  final void Function(String query)? open;
  final Widget child;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final open = this.open;
    if (open == null || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      open('');
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    final char = event.character;
    if (char == null ||
        char.trim().isEmpty ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    open(char);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: child,
  );
}
