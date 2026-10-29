// The desktop apps' window opens where it was last time, at the same size,
// maximized if it was. Windows, macOS and Linux; nothing elsewhere.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _key = 'window';
const _defaultSize = Size(1280, 720);
const _minSize = Size(360, 480);

bool get _desktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Puts the window where it was when the app last closed, then shows it.
/// The Windows runner leaves the window hidden for this. A place on a
/// screen that is gone now is moved onto the main screen, and a size that
/// doesn't fit there becomes the default.
Future<void> placeWindow() async {
  if (!_desktop) return;
  await windowManager.ensureInitialized();
  try {
    await windowManager.setMinimumSize(_minSize);
    final saved = await _load();
    final bounds = saved?.bounds == null
        ? null
        : await _onScreen(saved!.bounds!);
    if (bounds != null) {
      await windowManager.setBounds(bounds);
    } else {
      await windowManager.setSize(_defaultSize);
      await windowManager.center();
    }
    if (saved?.maximized ?? false) await windowManager.maximize();
    // Saved one last time on closing, which catches what no event tells:
    // on Windows only moves and resizes with the mouse are reported.
    await windowManager.setPreventClose(true);
  } catch (_) {
    // A window in the default place is better than none.
  } finally {
    await windowManager.show();
    await windowManager.focus();
  }
  windowManager.addListener(_Keeper());
}

/// The window's normal (not maximized) bounds, null when it has only ever
/// been maximized, and whether it was maximized.
typedef _Place = ({Rect? bounds, bool maximized});

Future<_Place?> _load() async {
  final text = (await SharedPreferences.getInstance()).getString(_key);
  if (text == null) return null;
  try {
    final j = jsonDecode(text) as Map<String, dynamic>;
    double n(String k) => (j[k] as num).toDouble();
    return (
      bounds: j['width'] == null
          ? null
          : Rect.fromLTWH(n('x'), n('y'), n('width'), n('height')),
      maximized: j['maximized'] == true,
    );
  } on Object {
    return null;
  }
}

/// [r], if enough of its top edge (where the title bar is) is on one of
/// the screens to take hold of; else centred on the main screen when it
/// fits there, or null.
Future<Rect?> _onScreen(Rect r) async {
  final screens = await screenRetriever.getAllDisplays();
  Rect area(Display d) {
    final p = d.visiblePosition ?? Offset.zero;
    final s = d.visibleSize ?? d.size;
    return Rect.fromLTWH(p.dx, p.dy, s.width, s.height);
  }

  final grip = Rect.fromLTWH(r.left + 40, r.top, r.width - 80, 32);
  for (final d in screens) {
    final seen = area(d).intersect(grip);
    if (!seen.isEmpty && seen.width >= 80 && seen.height >= 16) return r;
  }
  final main = area(await screenRetriever.getPrimaryDisplay());
  if (r.width > main.width || r.height > main.height) return null;
  return Rect.fromCenter(center: main.center, width: r.width, height: r.height);
}

/// Saves where the window is a moment after it moves or changes size, and
/// when it closes. A maximized window keeps the bounds it had before, so
/// that it comes back there when it is restored.
class _Keeper with WindowListener {
  Timer? _timer;
  bool _closing = false;

  void _later() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    try {
      if (await windowManager.isMinimized()) return;
      final maximized = await windowManager.isMaximized();
      final bounds = maximized
          ? (await _load())?.bounds
          : await windowManager.getBounds();
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode({
          if (bounds != null) ...{
            'x': bounds.left,
            'y': bounds.top,
            'width': bounds.width,
            'height': bounds.height,
          },
          'maximized': maximized,
        }),
      );
    } catch (_) {
      // Not saved this time; the next change or closing tries again.
    }
  }

  @override
  void onWindowMove() => _later();

  @override
  void onWindowResize() => _later();

  @override
  void onWindowMoved() => _later();

  @override
  void onWindowResized() => _later();

  @override
  void onWindowMaximize() => _later();

  @override
  void onWindowUnmaximize() => _later();

  @override
  Future<void> onWindowClose() async {
    if (_closing) return; // the close below comes here too
    _closing = true;
    _timer?.cancel();
    try {
      await _save();
    } finally {
      // Closed as if closing hadn't been held up: windowManager.destroy()
      // quits while this call waits, and the app then takes seconds to end.
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }
}
