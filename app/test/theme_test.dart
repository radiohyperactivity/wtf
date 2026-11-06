import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/session.dart';
import 'package:wtf/theme.dart';

void main() {
  // The System look: each platform's own colours and shapes, Apple's
  // dialogs and switches only on Apple's platforms, and Android as Material.
  test('the System look follows the platform', () {
    ThemeData system(TargetPlatform p, [Brightness b = Brightness.light]) =>
        appTheme(AppColour.system, b, p);

    final iphone = system(TargetPlatform.iOS);
    expect(iphone.colorScheme.primary, const Color(0xFF007AFF));
    expect(iphone.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(iphone.appBarTheme.centerTitle, isTrue);
    expect(iphone.extension<AppleLook>(), isNotNull);
    expect(iphone.navigationBarTheme.indicatorColor, Colors.transparent);
    expect(iphone.splashFactory, NoSplash.splashFactory);
    expect(
      system(TargetPlatform.macOS, Brightness.dark).colorScheme.primary,
      const Color(0xFF0A84FF),
    );

    final windows = system(TargetPlatform.windows);
    expect(windows.colorScheme.primary, const Color(0xFF005FB8));
    expect(windows.appBarTheme.centerTitle, isFalse);
    expect(windows.extension<AppleLook>(), isNull);

    final linux = system(TargetPlatform.linux, Brightness.dark);
    expect(linux.colorScheme.primary, const Color(0xFF3584E4));
    expect(linux.brightness, Brightness.dark);

    final android = system(TargetPlatform.android);
    expect(android.extension<AppleLook>(), isNull);
    expect(android.splashFactory, isNot(NoSplash.splashFactory));

    // Teal and Orange stay Material's, on Apple too.
    expect(
      appTheme(
        AppColour.teal,
        Brightness.light,
        TargetPlatform.iOS,
      ).extension<AppleLook>(),
      isNull,
    );
  });
}
