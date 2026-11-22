// The web app keeps no files of its own: the browser's cache keeps them, as
// the server says a file never changes. See file_cache.dart.

import 'dart:typed_data';

Future<Uint8List?> cachedFile(String hash, int size) async => null;

Future<void> cacheFile(String hash, int size, Uint8List bytes) async {}

Future<void> forgetCachedFile(String hash, int size) async {}

Future<void> forgetCachedFiles() async {}
