// Opening a downloaded attachment with the device's own app: the native
// apps. The web app opens the file's address instead (open_native_web.dart).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Writes [bytes] to [name] in a folder of the app's temporary directory
/// that is [key]'s own (the file's hash, so a changed file gets a folder of
/// its own), and opens it. False when no app opens it.
Future<bool> openNative(
  String key,
  String name,
  String type,
  Uint8List bytes,
) async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
    'wtf-open${Platform.pathSeparator}$key',
  );
  await dir.create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    // Through the system's file sharing, with the type.
    final result = await OpenFilex.open(file.path, type: type);
    return result.type == ResultType.done;
  }
  // Desktops: the file's own app, by its extension. Not through open_filex,
  // which runs "cmd /c start" on Windows, where a title with & in it would
  // be a command.
  return launchUrl(Uri.file(file.path));
}
