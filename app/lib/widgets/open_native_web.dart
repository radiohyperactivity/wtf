// The web app has no files of its own to open; it opens the file's address
// (open_native.dart is the native apps').

import 'dart:typed_data';

Future<bool> openNative(
  String key,
  String name,
  String type,
  Uint8List bytes,
) => throw UnsupportedError('The web app opens attachments by their address');
