// Keys for the forms: Ctrl+Enter (⌘+Enter on a Mac) saves from any field,
// and with Shift too, saves and starts another. Enter in a field goes on to
// the next one, and in the last one saves; the forms give their fields
// textInputAction and onFieldSubmitted for that.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart' show compactWidth;

class FormKeys extends StatelessWidget {
  const FormKeys({
    super.key,
    required this.save,
    this.saveAnother,
    required this.child,
  });

  final VoidCallback save;

  /// Saves, and opens the form again for another; null when the form has no
  /// such button.
  final VoidCallback? saveAnother;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final another = saveAnother;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): save,
        if (another != null) ...{
          const SingleActivator(
            LogicalKeyboardKey.enter,
            control: true,
            shift: true,
          ): another,
          const SingleActivator(
            LogicalKeyboardKey.enter,
            meta: true,
            shift: true,
          ): another,
        },
      },
      child: child,
    );
  }
}

/// The button for "save, and another": its words on wide screens, an icon
/// with a tooltip on phones, where the app bar has little room.
class AnotherButton extends StatelessWidget {
  const AnotherButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.playlist_add);
    if (MediaQuery.sizeOf(context).width < compactWidth) {
      return IconButton(icon: icon, tooltip: label, onPressed: onPressed);
    }
    return TextButton.icon(
      icon: icon,
      label: Text(label),
      onPressed: onPressed,
    );
  }
}
