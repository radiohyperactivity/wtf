// The app's colours, and the System look, which follows the platform's own
// apps.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'session.dart';

/// The logo's orange.
const logoOrange = Color(0xFFFF7828);

/// The app's theme in [colour], for [platform] (the one the app runs on, or
/// the browser's). Orange keeps close to the logo's (Material's "fidelity"
/// scheme); the usual scheme would tone it down to brown.
ThemeData appTheme(
  AppColour colour,
  Brightness brightness, [
  TargetPlatform? platform,
]) => switch (colour) {
  AppColour.system => _systemTheme(
    platform ?? defaultTargetPlatform,
    brightness,
  ),
  AppColour.teal => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
  ),
  AppColour.orange => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: logoOrange,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ),
  ),
};

/// Marks the System look on Apple's platforms, where dialogs and switches
/// are Apple's own.
class AppleLook extends ThemeExtension<AppleLook> {
  const AppleLook();

  @override
  AppleLook copyWith() => this;

  @override
  AppleLook lerp(AppleLook? other, double t) => this;
}

/// Whether the screen at [context] has the System look on an Apple device.
bool appleLook(BuildContext context) =>
    Theme.of(context).extension<AppleLook>() != null;

bool _isApple(TargetPlatform p) =>
    p == TargetPlatform.iOS || p == TargetPlatform.macOS;

/// The System look: on Android, Material as it is, which is Android's own;
/// elsewhere, the colours, shapes and text sizes of the platform's apps.
ThemeData _systemTheme(TargetPlatform platform, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final look = switch (platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => dark ? _appleDark : _apple,
    TargetPlatform.windows => dark ? _windowsDark : _windows,
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => dark ? _gnomeDark : _gnome,
    TargetPlatform.android => null,
  };
  if (look == null) {
    return ThemeData(brightness: brightness, platform: platform);
  }
  return _flatTheme(look, platform, brightness);
}

/// The colours and sizes of a platform's apps, in light or dark.
class _Look {
  const _Look({
    required this.accent,
    this.onAccent = Colors.white,
    required this.error,
    this.onError = Colors.white,
    required this.background,
    required this.bar,
    required this.card,
    required this.dialog,
    required this.field,
    required this.selection,
    required this.divider,
    required this.text,
    required this.secondaryText,
    required this.smallRadius,
    required this.largeRadius,
    this.hairline = 1,
    this.centerTitle = false,
    this.cardBorder = false,
    this.fieldBorder = false,
    required this.body,
    required this.small,
    required this.title,
    required this.barTitle,
    required this.heavy,
  });

  /// The one colour that stands out: selections, buttons, links.
  final Color accent, onAccent, error, onError;

  /// The page, the bars at its top and bottom, cards and groups, dialogs
  /// and menus, text fields, and a selected entry of the rail.
  final Color background, bar, card, dialog, field, selection;
  final Color divider, text, secondaryText;

  /// The corners of buttons and fields, and of cards and dialogs.
  final double smallRadius, largeRadius;

  /// The width of dividers.
  final double hairline;

  /// Titles in the middle of the top bar (Apple, GNOME), not on its left.
  final bool centerTitle;

  /// Cards and text fields with a line around them (Windows).
  final bool cardBorder, fieldBorder;

  /// Text sizes: the usual text (list entries, fields), smaller text, a
  /// screen's own titles, and the top bar's title; [heavy] is the weight of
  /// titles.
  final double body, small, title, barTitle;
  final FontWeight heavy;
}

// iOS and macOS: the system colours of Apple's Human Interface Guidelines,
// with plain (white or black) lists, grey groups, and San Francisco at
// Apple's sizes, which Flutter already uses as the font.
const _apple = _Look(
  accent: Color(0xFF007AFF),
  error: Color(0xFFFF3B30),
  background: Color(0xFFFFFFFF),
  bar: Color(0xFFF9F9F9),
  card: Color(0xFFF2F2F7),
  dialog: Color(0xFFFFFFFF),
  field: Color(0xFFF2F2F7),
  selection: Color(0xFFE5E5EA),
  divider: Color(0xFFC6C6C8),
  text: Color(0xFF000000),
  secondaryText: Color(0xFF8A8A8E),
  smallRadius: 10,
  largeRadius: 14,
  hairline: 0.5,
  centerTitle: true,
  body: 17,
  small: 15,
  title: 20,
  barTitle: 17,
  heavy: FontWeight.w600,
);
const _appleDark = _Look(
  accent: Color(0xFF0A84FF),
  error: Color(0xFFFF453A),
  background: Color(0xFF000000),
  bar: Color(0xFF1C1C1E),
  card: Color(0xFF1C1C1E),
  dialog: Color(0xFF2C2C2E),
  field: Color(0xFF1C1C1E),
  selection: Color(0xFF3A3A3C),
  divider: Color(0xFF38383A),
  text: Color(0xFFFFFFFF),
  secondaryText: Color(0xFF8E8E93),
  smallRadius: 10,
  largeRadius: 14,
  hairline: 0.5,
  centerTitle: true,
  body: 17,
  small: 15,
  title: 20,
  barTitle: 17,
  heavy: FontWeight.w600,
);

// Windows 11: Fluent's colours, with the default accent blue, white cards
// with a line around them on a light grey page, small corners, and Segoe UI
// at 14 points, which Flutter already uses as the font.
const _windows = _Look(
  accent: Color(0xFF005FB8),
  error: Color(0xFFC42B1C),
  background: Color(0xFFF3F3F3),
  bar: Color(0xFFF3F3F3),
  card: Color(0xFFFFFFFF),
  dialog: Color(0xFFFFFFFF),
  field: Color(0xFFFFFFFF),
  selection: Color(0xFFE6E6E6),
  divider: Color(0xFFE0E0E0),
  text: Color(0xFF1B1B1B),
  secondaryText: Color(0xFF616161),
  smallRadius: 4,
  largeRadius: 8,
  cardBorder: true,
  fieldBorder: true,
  body: 14,
  small: 13,
  title: 20,
  barTitle: 16,
  heavy: FontWeight.w600,
);
const _windowsDark = _Look(
  accent: Color(0xFF60CDFF),
  onAccent: Color(0xFF000000),
  error: Color(0xFFFF99A4),
  onError: Color(0xFF000000),
  background: Color(0xFF202020),
  bar: Color(0xFF202020),
  card: Color(0xFF2B2B2B),
  dialog: Color(0xFF2B2B2B),
  field: Color(0xFF2D2D2D),
  selection: Color(0xFF2D2D2D),
  divider: Color(0xFF3B3B3B),
  text: Color(0xFFFFFFFF),
  secondaryText: Color(0xFFC5C5C5),
  smallRadius: 4,
  largeRadius: 8,
  cardBorder: true,
  fieldBorder: true,
  body: 14,
  small: 13,
  title: 20,
  barTitle: 16,
  heavy: FontWeight.w600,
);

// Linux: GNOME's Adwaita, with its blue, titles in the middle of the top
// bar, grey text fields and rounder corners.
const _gnome = _Look(
  accent: Color(0xFF3584E4),
  error: Color(0xFFE01B24),
  background: Color(0xFFFAFAFB),
  bar: Color(0xFFFFFFFF),
  card: Color(0xFFFFFFFF),
  dialog: Color(0xFFFFFFFF),
  field: Color(0xFFEBEBED),
  selection: Color(0xFFE6E6E8),
  divider: Color(0xFFE0E0E2),
  text: Color(0xFF323235),
  secondaryText: Color(0xFF77767B),
  smallRadius: 6,
  largeRadius: 12,
  centerTitle: true,
  body: 15,
  small: 13,
  title: 20,
  barTitle: 15,
  heavy: FontWeight.w700,
);
const _gnomeDark = _Look(
  accent: Color(0xFF3584E4),
  error: Color(0xFFFF7B63),
  onError: Color(0xFF000000),
  background: Color(0xFF222226),
  bar: Color(0xFF2E2E32),
  card: Color(0xFF2E2E32),
  dialog: Color(0xFF36363A),
  field: Color(0xFF3A3A3E),
  selection: Color(0xFF3A3A3E),
  divider: Color(0xFF3C3C40),
  text: Color(0xFFFFFFFF),
  secondaryText: Color(0xFFAAAAAD),
  smallRadius: 6,
  largeRadius: 12,
  centerTitle: true,
  body: 15,
  small: 13,
  title: 20,
  barTitle: 15,
  heavy: FontWeight.w700,
);

/// Material made to look like [look]: neutral surfaces instead of ones
/// tinted with the accent, flat bars, small corners, no ripples, and the
/// platform's text sizes.
ThemeData _flatTheme(_Look look, TargetPlatform platform, Brightness b) {
  final apple = _isApple(platform);
  final tint = Color.alphaBlend(
    look.accent.withValues(alpha: 0.15),
    look.background,
  );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: look.accent,
        brightness: b,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: look.accent,
        onPrimary: look.onAccent,
        primaryContainer: tint,
        onPrimaryContainer: look.text,
        secondary: look.accent,
        onSecondary: look.onAccent,
        secondaryContainer: tint,
        onSecondaryContainer: look.text,
        error: look.error,
        onError: look.onError,
        surface: look.background,
        onSurface: look.text,
        onSurfaceVariant: look.secondaryText,
        surfaceContainerLowest: look.card,
        surfaceContainerLow: look.card,
        surfaceContainer: look.bar,
        surfaceContainerHigh: look.dialog,
        surfaceContainerHighest: look.field,
        outline: Color.lerp(look.divider, look.secondaryText, 0.4),
        outlineVariant: look.divider,
        surfaceTint: Colors.transparent,
      );

  final base = ThemeData(brightness: b, platform: platform).textTheme;
  TextStyle size(TextStyle? s, double size, [FontWeight? weight]) =>
      s!.copyWith(
        fontSize: size,
        fontWeight: weight,
        letterSpacing: 0,
        color: look.text,
      );
  final text = base.copyWith(
    titleLarge: size(base.titleLarge, look.title, look.heavy),
    titleMedium: size(base.titleMedium, look.body, look.heavy),
    titleSmall: size(base.titleSmall, look.small, look.heavy),
    bodyLarge: size(base.bodyLarge, look.body),
    bodyMedium: size(base.bodyMedium, look.small),
    bodySmall: size(base.bodySmall, look.small - 2),
    labelLarge: size(base.labelLarge, look.small, FontWeight.w500),
    labelMedium: size(base.labelMedium, look.small - 2),
    labelSmall: size(base.labelSmall, look.small - 4),
  );

  final small = BorderRadius.circular(look.smallRadius);
  final large = BorderRadius.circular(look.largeRadius);
  final smallShape = RoundedRectangleBorder(borderRadius: small);
  OutlineInputBorder field(Color? line, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: small,
        borderSide: line == null
            ? BorderSide.none
            : BorderSide(color: line, width: width),
      );
  WidgetStateProperty<Color> selectedOr(Color selected, Color other) =>
      WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? selected : other,
      );

  return ThemeData(
    colorScheme: scheme,
    platform: platform,
    textTheme: text,
    scaffoldBackgroundColor: look.background,
    dividerColor: look.divider,
    // None of these platforms shows a ripple where it is tapped.
    splashFactory: NoSplash.splashFactory,
    extensions: [if (apple) const AppleLook()],
    appBarTheme: AppBarTheme(
      backgroundColor: look.bar,
      foregroundColor: look.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: look.centerTitle,
      shape: Border(
        bottom: BorderSide(color: look.divider, width: look.hairline),
      ),
      titleTextStyle: size(base.titleLarge, look.barTitle, look.heavy),
    ),
    // On Apple, the bottom bar is a tab bar: no shape behind the selected
    // tab, which is in the accent colour instead.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: look.bar,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      height: apple ? 56 : 64,
      indicatorColor: apple ? Colors.transparent : look.selection,
      indicatorShape: smallShape,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelSmall!.copyWith(
          fontSize: apple ? 10 : 12,
          fontWeight: FontWeight.w500,
          color: s.contains(WidgetState.selected)
              ? look.accent
              : look.secondaryText,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? look.accent
              : look.secondaryText,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: look.bar,
      indicatorColor: look.selection,
      indicatorShape: smallShape,
      selectedIconTheme: IconThemeData(color: look.accent),
      unselectedIconTheme: IconThemeData(color: look.secondaryText),
      selectedLabelTextStyle: text.labelMedium!.copyWith(color: look.accent),
      unselectedLabelTextStyle: text.labelMedium!.copyWith(
        color: look.secondaryText,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: smallShape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: smallShape,
        side: BorderSide(color: look.divider),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: smallShape),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: smallShape, elevation: 0),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(smallShape),
        side: WidgetStatePropertyAll(BorderSide(color: look.divider)),
        backgroundColor: selectedOr(look.selection, Colors.transparent),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: look.accent,
      foregroundColor: look.onAccent,
      elevation: 2,
      highlightElevation: 2,
      shape: apple
          ? const StadiumBorder()
          : RoundedRectangleBorder(borderRadius: large),
    ),
    cardTheme: CardThemeData(
      color: look.card,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: large,
        side: look.cardBorder
            ? BorderSide(color: look.divider)
            : BorderSide.none,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: look.dialog,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: large),
      titleTextStyle: size(base.titleLarge, look.body + 1, look.heavy),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: look.dialog,
      surfaceTintColor: Colors.transparent,
      shape: smallShape,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: look.dialog,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(look.largeRadius),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: smallShape,
    ),
    dividerTheme: DividerThemeData(
      color: look.divider,
      thickness: look.hairline,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(iconColor: look.secondaryText),
    chipTheme: ChipThemeData(shape: smallShape),
    // Fields are filled, with small corners: a line around them only on
    // Windows, and the accent around the one being typed in. The forms'
    // own outline (OutlineInputBorder) gives way to these.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: look.field,
      border: field(look.fieldBorder ? look.divider : null),
      enabledBorder: field(look.fieldBorder ? look.divider : null),
      disabledBorder: field(look.fieldBorder ? look.divider : null),
      focusedBorder: field(look.accent, 2),
      errorBorder: field(look.error),
      focusedErrorBorder: field(look.error, 2),
    ),
  );
}
