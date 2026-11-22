// The files of photos and attachments, kept on disk by the native apps, so
// that a photo seen once shows at once, also after the app is started
// again. A file's address has its hash, and its content never changes, so
// a kept file is never out of date. The web app has the browser's cache
// instead (file_cache_web.dart).
//
// Kept in the app's cache directory, which the phone may empty when it
// needs room; past [_limit] bytes, the files used longest ago go first.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// At most this many bytes are kept; trimming leaves three quarters.
const _limit = 200 * 1024 * 1024;

/// The directory, once found and trimmed; null where there is none (in
/// tests, say), and nothing is kept.
final Future<Directory?> _dir = _open();

Future<Directory?> _open() async {
  try {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}files');
    await dir.create(recursive: true);
    await _trim(dir);
    return dir;
  } on Object {
    return null;
  }
}

/// Removes the files used longest ago, while there are more than [_limit]
/// bytes.
Future<void> _trim(Directory dir) async {
  final files = <(File, FileStat)>[];
  var total = 0;
  await for (final e in dir.list()) {
    if (e is! File) continue;
    final stat = await e.stat();
    files.add((e, stat));
    total += stat.size;
  }
  if (total <= _limit) return;
  files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
  for (final (file, stat) in files) {
    if (total <= _limit * 3 ~/ 4) break;
    try {
      await file.delete();
      total -= stat.size;
    } on FileSystemException {
      // In use, or gone already.
    }
  }
}

/// A file's name in the directory, from what the server gives it: its hash
/// and the thumbnail size (0 for the file itself). Null for a hash that
/// isn't one, which is then not kept.
String? _name(String hash, int size) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ? '$hash-$size' : null;

/// The kept content of the file with [hash], as a thumbnail of [size] (0:
/// the file itself), if there is one.
Future<Uint8List?> cachedFile(String hash, int size) async {
  final dir = await _dir;
  final name = _name(hash, size);
  if (dir == null || name == null) return null;
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  try {
    final bytes = await file.readAsBytes();
    // Used now: the last to go when trimming.
    file.setLastModified(DateTime.now()).ignore();
    return bytes;
  } on FileSystemException {
    return null;
  }
}

/// Keeps [bytes] as the file with [hash], as a thumbnail of [size] (0: the
/// file itself). Written beside it first and renamed, so that a half-written
/// file is never read.
Future<void> cacheFile(String hash, int size, Uint8List bytes) async {
  final dir = await _dir;
  final name = _name(hash, size);
  if (dir == null || name == null) return;
  final path = '${dir.path}${Platform.pathSeparator}$name';
  final part = File('$path.part');
  try {
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(path);
  } on FileSystemException {
    // Not kept: it is downloaded again next time.
  }
}

/// Removes a kept file whose content turned out to be damaged.
Future<void> forgetCachedFile(String hash, int size) async {
  final dir = await _dir;
  final name = _name(hash, size);
  if (dir == null || name == null) return;
  try {
    await File('${dir.path}${Platform.pathSeparator}$name').delete();
  } on FileSystemException {
    // Gone already.
  }
}

/// Removes every kept file: at logout, so that the next account's user
/// doesn't find this one's photos on the device.
Future<void> forgetCachedFiles() async {
  final dir = await _dir;
  if (dir == null) return;
  try {
    await for (final e in dir.list()) {
      if (e is File) await e.delete();
    }
  } on FileSystemException {
    // What is left is trimmed in time.
  }
}
