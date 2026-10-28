// The app's colours.

import 'package:flutter/material.dart';

import 'session.dart';

/// The logo's orange.
const logoOrange = Color(0xFFFF7828);

/// The app's theme in [colour]. Orange keeps close to the logo's (Material's
/// "fidelity" scheme); the usual scheme would tone it down to brown.
ThemeData appTheme(AppColour colour, Brightness brightness) => ThemeData(
  colorScheme: switch (colour) {
    AppColour.teal => ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
    AppColour.orange => ColorScheme.fromSeed(
      seedColor: logoOrange,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ),
  },
);
