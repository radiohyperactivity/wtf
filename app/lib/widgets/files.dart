// Files of items, stock rows and locations: their photo, and the files of
// the attachment attributes of items and stock rows (api/attachment.md). Showing, opening, saving, uploading and
// removing them.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import 'common.dart';
import 'link.dart';
import 'open_native.dart' if (dart.library.js_interop) 'open_native_web.dart';

/// A photo, loaded from the API with the session. With [decode] it is
/// decoded to fit that box (in logical pixels, an infinite side being no
/// limit) instead of at full size, so a phone photo shown small doesn't
/// take tens of megabytes of memory; and when both sides are known, the
/// server sends a thumbnail that size, so it isn't downloaded at full size
/// either. The native apps keep what they download (file_cache.dart).
class FileImage extends StatelessWidget {
  const FileImage(
    this.file, {
    super.key,
    this.fit = BoxFit.cover,
    this.size,
    this.decode,
  });

  final FileRef file;
  final BoxFit fit;
  final double? size;
  final Size? decode;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    int? pixels(double side) => side.isFinite ? (side * ratio).ceil() : null;
    final box = decode;
    final width = box == null ? null : pixels(box.width);
    final height = box == null ? null : pixels(box.height);
    // A thumbnail fits in a square: the longer of the box's sides.
    final thumbnail = width != null && height != null
        ? (width > height ? width : height)
        : null;
    ImageProvider image = kIsWeb
        ? NetworkImage(
            client.fileUrl(file, size: thumbnail).toString(),
            headers: client.authHeaders,
          )
        : ApiImage(client, file, thumbnail);
    if (width != null || height != null) {
      image = ResizeImage(
        image,
        width: width,
        height: height,
        policy: ResizeImagePolicy.fit,
      );
    }
    return Image(
      image: image,
      fit: fit,
      width: size,
      height: size,
      errorBuilder: (context, error, stack) => SizedBox(
        width: size,
        height: size,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}

/// A file's image, or its thumbnail of [size], read through
/// [ApiClient.fileBytes]: from this device when kept, else downloaded with
/// the session. Content that can't be decoded is forgotten, so that a
/// damaged copy isn't shown again.
@immutable
class ApiImage extends ImageProvider<ApiImage> {
  const ApiImage(this.client, this.file, this.size);

  final ApiClient client;
  final FileRef file;
  final int? size;

  /// The address it is downloaded from.
  String get url => client.fileUrl(file, size: size).toString();

  @override
  Future<ApiImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ApiImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await client.fileBytes(file, size: size);
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } on Object {
      await client.forgetFile(file, size: size);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is ApiImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// An image with a thin border, so one whose background is just off the
/// app's doesn't look misplaced.
class _Framed extends StatelessWidget {
  const _Framed({required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    foregroundDecoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(radius),
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: child),
  );
}

/// An object's small photo in a list, or when it has none [icon] in a frame
/// of the same size, so the names line up.
class PhotoOrIcon extends StatelessWidget {
  const PhotoOrIcon(
    this.photo, {
    super.key,
    required this.icon,
    this.size = 48,
  });

  final FileRef? photo;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = this.photo;
    // Cropped to a square, so decoded to twice the size: the shorter side
    // of an image up to twice as long as wide still covers it sharply.
    if (photo != null) {
      return _Framed(
        radius: 6,
        child: FileImage(photo, size: size, decode: Size.square(size * 2)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: size / 2, color: scheme.onSurfaceVariant),
    );
  }
}

/// An object's photo on its screen, framed, as wide as there is room (up
/// to [maxWidth] and [maxHeight]); tap to zoom.
class ObjectPhoto extends StatelessWidget {
  const ObjectPhoto(
    this.photo, {
    super.key,
    this.maxWidth = double.infinity,
    this.maxHeight = double.infinity,
  });

  final FileRef photo;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
    child: InkWell(
      onTap: () => showPhoto(context, photo),
      child: _Framed(
        radius: 8,
        child: LayoutBuilder(
          builder: (context, c) => FileImage(
            photo,
            fit: BoxFit.contain,
            decode: Size(c.maxWidth, c.maxHeight),
          ),
        ),
      ),
    ),
  );
}

/// An object's details with its [photo]: to their right on wide screens,
/// under them and as wide as the screen on narrow ones (so above the next
/// section).
class WithPhoto extends StatelessWidget {
  const WithPhoto({super.key, required this.photo, required this.children});

  final FileRef? photo;
  final List<Widget> children;

  /// The narrowest screen with the photo next to the details.
  static const wide = 600.0;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    final photo = this.photo;
    if (photo == null) return details;
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: details),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
                  child: ObjectPhoto(photo, maxWidth: 240, maxHeight: 320),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ObjectPhoto(photo),
                ),
              ],
            ),
    );
  }
}

/// The icon of a file of [mediaType]: the common sub-types their own, the
/// major types a default each, and a plain file for the rest.
IconData typeIcon(String mediaType) {
  final type = mediaType.split(';').first.trim().toLowerCase();
  final major = type.split('/').first;
  return switch (type) {
    'application/pdf' => Icons.picture_as_pdf_outlined,
    'application/msword' ||
    'application/rtf' ||
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
    'application/vnd.oasis.opendocument.text' => Icons.description_outlined,
    'text/csv' ||
    'application/vnd.ms-excel' ||
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' ||
    'application/vnd.oasis.opendocument.spreadsheet' =>
      Icons.table_chart_outlined,
    'application/vnd.ms-powerpoint' ||
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
    'application/vnd.oasis.opendocument.presentation' =>
      Icons.slideshow_outlined,
    'application/zip' ||
    'application/gzip' ||
    'application/x-tar' ||
    'application/x-7z-compressed' ||
    'application/vnd.rar' ||
    'application/x-rar-compressed' => Icons.folder_zip_outlined,
    'application/json' ||
    'application/xml' ||
    'text/xml' ||
    'application/yaml' ||
    'text/yaml' => Icons.data_object,
    'text/html' => Icons.html,
    'text/javascript' ||
    'application/javascript' ||
    'text/x-python' ||
    'application/x-sh' ||
    'text/x-c' => Icons.code,
    'text/markdown' => Icons.article_outlined,
    'text/calendar' => Icons.event_outlined,
    'text/vcard' => Icons.contact_page_outlined,
    'application/epub+zip' => Icons.menu_book_outlined,
    'image/svg+xml' => Icons.draw_outlined,
    'application/x-msdownload' ||
    'application/x-msi' ||
    'application/vnd.android.package-archive' ||
    'application/x-executable' => Icons.terminal,
    _ => switch (major) {
      'image' => Icons.image_outlined,
      'audio' => Icons.audio_file_outlined,
      'video' => Icons.video_file_outlined,
      'text' => Icons.text_snippet_outlined,
      'font' => Icons.font_download_outlined,
      'model' => Icons.view_in_ar_outlined,
      _ => Icons.insert_drive_file_outlined,
    },
  };
}

/// The icon of an attachment attribute's files: its type's, when it takes
/// one type only, else a plain file.
IconData attributeIcon(Attribute a) =>
    a.media.length == 1 ? typeIcon(a.media.single) : Icons.attach_file;

/// Shows a photo over the whole screen, to zoom into.
void showPhoto(BuildContext context, FileRef photo) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text(photo.title)),
        body: InteractiveViewer(
          maxScale: 8,
          child: Center(child: FileImage(photo, fit: BoxFit.contain)),
        ),
      ),
    ),
  );
}

/// Saves a downloaded file: a save dialog in the native apps, a download in
/// the browser. Tests replace it.
Future<void> Function(String name, Uint8List bytes) saveDownloadedFile =
    (name, bytes) async {
      await FilePicker.saveFile(
        dialogTitle: 'Save $name',
        fileName: name,
        bytes: bytes,
      );
    };

/// Downloads a file and saves it, named as the server names it (after the
/// attribute, or "Photo").
Future<void> saveFile(BuildContext context, FileRef f) async {
  final client = context.read<Session>().client;
  final messenger = ScaffoldMessenger.of(context);
  showMessage(context, 'Downloading ${f.title}…');
  try {
    final d = await client.download(f);
    messenger.hideCurrentSnackBar();
    await saveDownloadedFile(d.name, d.bytes);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
  }
}

/// The types the native apps open with the device's own app, with their
/// extensions (the first is the one a file gets). Documents, pictures,
/// sound, video and models only: nothing that runs or may run code
/// (programs, scripts, web pages, SVG, Office files with macros, the old
/// Office formats) is opened from the app; those are saved instead.
const _openExtensions = <String, List<String>>{
  'image/jpeg': ['jpg', 'jpeg'],
  'image/png': ['png'],
  'image/gif': ['gif'],
  'image/webp': ['webp'],
  'image/heic': ['heic'],
  'application/pdf': ['pdf'],
  'text/plain': ['txt'],
  'text/markdown': ['md'],
  'text/csv': ['csv'],
  'application/json': ['json'],
  'application/zip': ['zip'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': [
    'docx',
  ],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['xlsx'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': [
    'pptx',
  ],
  'application/vnd.oasis.opendocument.text': ['odt'],
  'application/vnd.oasis.opendocument.spreadsheet': ['ods'],
  'application/vnd.oasis.opendocument.presentation': ['odp'],
  'audio/mpeg': ['mp3'],
  'audio/mp4': ['m4a'],
  'video/mp4': ['mp4'],
  'video/quicktime': ['mov'],
  'model/stl': ['stl'],
  'model/step': ['step', 'stp'],
};

/// Whether the native apps open files of [type] with the device's own app.
bool canOpenType(String type) => _openExtensions.containsKey(type);

/// The name of the file the native apps open: [name] (as the server names
/// it), with characters that file systems or shells treat specially
/// replaced, and always ending in the type's extension, so the device
/// picks the app by the type.
String openFileName(String name, String type) {
  final extensions = _openExtensions[type] ?? const ['bin'];
  var stem = name.replaceAll(
    RegExp(r'[^\p{L}\p{N} ._()-]', unicode: true),
    '_',
  );
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  stem = stem.replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (stem.length > 100) stem = stem.substring(0, 100).trimRight();
  if (stem.isEmpty) stem = 'file';
  return '$stem.${extensions.first}';
}

/// Opens a downloaded file with the device's own app; false when none
/// opens it. Tests replace it.
Future<bool> Function(FileRef f, String name, String type, Uint8List bytes)
openDownloadedFile = (f, name, type, bytes) =>
    openNative(f.hash, name, type, bytes);

/// Opens a file: the web app in a new tab of the browser (which shows what
/// the server sends inline, and downloads the rest), the native apps with
/// the device's own app for its type, from a copy in the app's temporary
/// files. A type the native apps don't open is saved instead.
Future<void> openFile(BuildContext context, FileRef f) async {
  final session = context.read<Session>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (session.isWeb) {
      await openLink(session.client.fileUrl(f));
      return;
    }
    showMessage(context, 'Opening ${f.title}…');
    final d = await session.client.download(f);
    messenger.hideCurrentSnackBar();
    if (!canOpenType(d.type)) {
      // Something that could run code: saved, not opened.
      await saveDownloadedFile(d.name, d.bytes);
      return;
    }
    final opened = await openDownloadedFile(
      f,
      openFileName(d.name, d.type),
      d.type,
      d.bytes,
    );
    if (!opened && context.mounted) {
      showMessage(
        context,
        'Nothing on this device opens ${d.type} files. Save it instead.',
      );
    }
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
  }
}

/// Whether this device can take a photo: phones (and phone browsers, which
/// offer the camera for a photo upload); not desktops. Tests replace it.
bool Function(BuildContext context) canTakePhoto = _canTakePhoto;

bool _canTakePhoto(BuildContext context) {
  final picker = ImagePicker();
  if (!picker.supportsImageSource(ImageSource.camera)) return false;
  if (kIsWeb) return MediaQuery.sizeOf(context).shortestSide < 600;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// A file chosen to upload: its name, and a way to read it.
typedef PickedFile = (String name, Future<List<int>> Function() read);

/// Lets the user choose a file to upload (an image, with [image]); null
/// when cancelled. Tests replace it.
Future<PickedFile?> Function({bool image}) pickUploadFile =
    ({bool image = false}) async {
      final files = await FilePicker.pickFiles(
        dialogTitle: image ? 'Choose a photo' : 'Choose a file',
        type: image ? FileType.image : FileType.any,
      );
      if (files.isEmpty) return null;
      return (files.first.name, files.first.readAsBytes);
    };

/// Takes a photo with the camera; null when cancelled. Tests replace it.
Future<PickedFile?> Function() takeCameraPhoto = () async {
  final shot = await ImagePicker().pickImage(source: ImageSource.camera);
  return shot == null ? null : (shot.name, shot.readAsBytes);
};

/// Uploads [file] with [send], saying so; true when done.
Future<bool> _upload(
  BuildContext context,
  PickedFile file,
  Future<void> Function(String name, List<int> bytes) send,
) async {
  final messenger = ScaffoldMessenger.of(context);
  showMessage(context, 'Uploading ${file.$1}…');
  try {
    await send(file.$1, await file.$2());
    messenger.hideCurrentSnackBar();
    if (context.mounted) showMessage(context, 'Uploaded ${file.$1}.');
    return true;
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Whether this app can fetch a file from an address on the web: the
/// native apps; not the web app, as most sites don't let a page of another
/// site read their files.
const canFetchUrl = !kIsWeb;

/// Why a file couldn't be fetched from an address, said for people.
class FetchError implements Exception {
  const FetchError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The largest file fetched from an address: what wtfd takes by default
/// (--max-attachment-size). A larger one would be refused by it anyway.
const fetchLimit = 100 << 20;

/// The address typed, when it is one a file can be fetched from: http or
/// https, with a host; else null.
Uri? fetchableUrl(String text) {
  final url = Uri.tryParse(text.trim());
  if (url == null || url.host.isEmpty) return null;
  if (!url.isScheme('https') && !url.isScheme('http')) return null;
  return url;
}

/// Asks for the address of a file; null when cancelled.
Future<Uri?> askUrl(BuildContext context, {required String title}) async {
  final text = await askText(
    context,
    title: title,
    label: 'Address, https://…',
    action: 'Fetch',
    keyboardType: TextInputType.url,
    validate: (text) => fetchableUrl(text) == null
        ? 'An address that starts with https:// or http://'
        : null,
  );
  return text == null ? null : fetchableUrl(text);
}

/// Fetches the file at [url] with this device, to upload as if chosen from
/// its disk, named as the site names it, or after the address's last part.
/// Tests replace it.
Future<PickedFile> Function(Uri url) fetchUrlFile = fetchFromUrl;

/// [fetchUrlFile], with [client] (tests give one).
Future<PickedFile> fetchFromUrl(Uri url, {http.Client? client}) async {
  final http_ = client ?? http.Client();
  try {
    final http.StreamedResponse resp;
    try {
      resp = await http_
          .send(http.Request('GET', url))
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw FetchError("${url.host} didn't answer within 30 seconds.");
    } on Object {
      throw FetchError("Can't reach ${url.host}. Check the address.");
    }
    if (resp.statusCode != 200) {
      final reason = resp.reasonPhrase == null ? '' : ' ${resp.reasonPhrase}';
      throw FetchError(
        '${url.host} answered ${resp.statusCode}$reason: '
        'there is no file to fetch at that address.',
      );
    }
    final type = (resp.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    if (type == 'text/html' || type == 'application/xhtml+xml') {
      throw const FetchError(
        'That address is a web page, not a file. On the page, copy the '
        'address of the image or file itself.',
      );
    }
    if ((resp.contentLength ?? 0) > fetchLimit) {
      throw const FetchError(
        'That file is larger than ${fetchLimit >> 20} MB, more than a file '
        'may be.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in resp.stream.timeout(
        const Duration(seconds: 30),
      )) {
        bytes.add(chunk);
        if (bytes.length > fetchLimit) {
          throw const FetchError(
            'That file is larger than ${fetchLimit >> 20} MB, more than a '
            'file may be.',
          );
        }
      }
    } on TimeoutException {
      throw FetchError('${url.host} stopped sending the file.');
    }
    final last = url.pathSegments.lastWhere(
      (s) => s.isNotEmpty,
      orElse: () => url.host,
    );
    final name = downloadName(resp.headers['content-disposition']) ?? last;
    final content = bytes.takeBytes();
    return (name, () async => content);
  } finally {
    if (client == null) http_.close();
  }
}

/// Fetches the file at [url], then uploads it with [send], saying so; true
/// when done.
Future<bool> _fetchAndUpload(
  BuildContext context,
  Uri url,
  Future<void> Function(String name, List<int> bytes) send,
) async {
  final messenger = ScaffoldMessenger.of(context);
  showMessage(context, 'Fetching from ${url.host}…');
  final PickedFile file;
  try {
    file = await fetchUrlFile(url);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
    return false;
  }
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return false;
  return _upload(context, file, send);
}

/// The photo of the item, stock row or location at [owner] (/items/{id},
/// /stock/{id} or /locations/{id}): choose an image, take one or fetch one
/// from an address, or remove it. True when it changed.
Future<bool> editPhoto(
  BuildContext context, {
  required String owner,
  required bool hasPhoto,
  required Future<void> Function() remove,
}) async {
  final client = context.read<Session>().client;
  final camera = canTakePhoto(context);
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // There is one photo: each way of giving one replaces it.
          if (hasPhoto)
            ListTile(
              dense: true,
              title: Text(
                'Replaces the current photo',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Choose a photo'),
            onTap: () => Navigator.pop(context, 'choose'),
          ),
          if (camera)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'take'),
            ),
          if (canFetchUrl)
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('From a URL'),
              onTap: () => Navigator.pop(context, 'url'),
            ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.hide_image_outlined),
              title: const Text('Remove the photo'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  try {
    switch (action) {
      case 'remove':
        await remove();
        return true;
      case 'take':
        final shot = await takeCameraPhoto();
        if (shot == null || !context.mounted) return false;
        return await _upload(
          context,
          shot,
          (name, bytes) => client.uploadPhoto(owner, name: name, bytes: bytes),
        );
      case 'url':
        final url = await askUrl(context, title: 'Fetch a photo');
        if (url == null || !context.mounted) return false;
        return await _fetchAndUpload(
          context,
          url,
          (name, bytes) => client.uploadPhoto(owner, name: name, bytes: bytes),
        );
      default:
        final file = await pickUploadFile(image: true);
        if (file == null || !context.mounted) return false;
        return await _upload(
          context,
          file,
          (name, bytes) => client.uploadPhoto(owner, name: name, bytes: bytes),
        );
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// The images every app can show: anything else gets its type's icon.
const _showable = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/bmp',
};

/// An attachment's file in a list: a small picture of it when it is an
/// image, else its type's icon (a PDF's, a spreadsheet's…). Until its type
/// is known, and if it can't be, [fallback], the attribute's icon.
class _FileLeading extends StatefulWidget {
  const _FileLeading(this.file, {required this.fallback});

  final FileRef file;
  final IconData fallback;

  @override
  State<_FileLeading> createState() => _FileLeadingState();
}

class _FileLeadingState extends State<_FileLeading> {
  String? _type;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void didUpdateWidget(_FileLeading old) {
    super.didUpdateWidget(old);
    if (old.file.hash != widget.file.hash) _find();
  }

  Future<void> _find() async {
    final client = context.read<Session>().client;
    final hash = widget.file.hash;
    _type = client.knownFileType(hash);
    if (_type != null) return;
    try {
      final type = await client.fileType(widget.file);
      if (mounted && hash == widget.file.hash) setState(() => _type = type);
    } on Object {
      // The attribute's icon stays: the file opens, or says why not, when
      // tapped.
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = _type;
    if (type != null && _showable.contains(type)) {
      return PhotoOrIcon(widget.file, icon: widget.fallback);
    }
    return PhotoOrIcon(
      null,
      icon: type == null || type.isEmpty ? widget.fallback : typeIcon(type),
    );
  }
}

/// An attachment attribute of the item or stock row at [owner]: its file,
/// if it has one, to open or save; with [onChanged] (when the account may
/// change it), to upload, fetch from an address, replace or remove ([remove] sends the PATCH that
/// does).
class FileValueTile extends StatelessWidget {
  const FileValueTile({
    super.key,
    required this.owner,
    required this.attribute,
    required this.hash,
    this.onChanged,
    this.remove,
  });

  final String owner;
  final Attribute attribute;

  /// The file's hash; null when there is none.
  final String? hash;
  final VoidCallback? onChanged;
  final Future<void> Function()? remove;

  FileRef? get _file => hash == null
      ? null
      : FileRef(owner: owner, attribute: attribute.name, hash: hash!);

  Future<void> _choose(BuildContext context) async {
    final client = context.read<Session>().client;
    final file = await pickUploadFile();
    if (file == null || !context.mounted) return;
    final done = await _upload(
      context,
      file,
      (name, bytes) =>
          client.uploadFile(owner, attribute.name, name: name, bytes: bytes),
    );
    if (done) onChanged!();
  }

  Future<void> _fetch(BuildContext context) async {
    final client = context.read<Session>().client;
    final url = await askUrl(context, title: 'Fetch ${attribute.name}');
    if (url == null || !context.mounted) return;
    final done = await _fetchAndUpload(
      context,
      url,
      (name, bytes) =>
          client.uploadFile(owner, attribute.name, name: name, bytes: bytes),
    );
    if (done) onChanged!();
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final write = onChanged != null;
    final takes = attribute.media.isEmpty
        ? null
        : 'Takes ${attribute.media.join(', ')}';
    return ListTile(
      leading: file == null
          ? PhotoOrIcon(null, icon: attributeIcon(attribute))
          : _FileLeading(file, fallback: attributeIcon(attribute)),
      title: Text(attribute.name),
      subtitle: Text(
        file == null ? ['No file', ?takes].join('. ') : 'Tap to open',
      ),
      onTap: file != null
          ? () => openFile(context, file)
          : write
          ? () => _choose(context)
          : null,
      trailing: file == null && !write
          ? null
          : PopupMenuButton<String>(
              tooltip: attribute.name,
              onSelected: (action) async {
                switch (action) {
                  case 'open':
                    openFile(context, file!);
                  case 'save':
                    saveFile(context, file!);
                  case 'upload':
                    _choose(context);
                  case 'url':
                    _fetch(context);
                  case 'remove':
                    if (!await confirm(
                      context,
                      title: 'Remove the file of ${attribute.name}?',
                      message: "This can't be undone.",
                      action: 'Remove',
                    )) {
                      return;
                    }
                    try {
                      await remove!();
                      onChanged!();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                }
              },
              itemBuilder: (context) => [
                if (file != null) ...[
                  const PopupMenuItem(value: 'open', child: Text('Open')),
                  const PopupMenuItem(value: 'save', child: Text('Save…')),
                ],
                if (write) ...[
                  PopupMenuItem(
                    value: 'upload',
                    child: Text(file == null ? 'Upload…' : 'Replace…'),
                  ),
                  if (canFetchUrl)
                    const PopupMenuItem(
                      value: 'url',
                      child: Text('Fetch from URL…'),
                    ),
                  if (file != null)
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove…'),
                    ),
                ],
              ],
            ),
    );
  }
}

/// A photo or an attachment attribute's file on a form (decision 115):
/// one chosen there, sent once the item or stock row it belongs to is
/// saved, or the one it has removed. Nothing chosen keeps what there is.
class FormFile {
  /// The photo; [current] is the one there now, when editing.
  FormFile.photo({this.current}) : attribute = null;

  /// The file of [attribute]; [current] is the one there now, when editing.
  FormFile.attribute(Attribute this.attribute, {this.current});

  /// Null for the photo.
  final Attribute? attribute;
  final FileRef? current;

  PickedFile? picked;

  /// Whether saving removes [current].
  bool removing = false;

  bool get isPhoto => attribute == null;
  String get label => attribute?.name ?? 'Photo';

  /// Whether saving changes anything.
  bool get changed => picked != null || removing;

  /// Whether a photo taken with the camera can be it: the photo, or an
  /// attribute taking images (or any type).
  bool get takesImages =>
      isPhoto ||
      attribute!.media.isEmpty ||
      attribute!.media.any((m) => m.startsWith('image/'));

  /// The same one, for the class's [attribute] (after another class is
  /// chosen), keeping what was chosen.
  FormFile again(Attribute attribute, {FileRef? current}) =>
      FormFile.attribute(attribute, current: current)
        ..picked = picked
        ..removing = removing && current != null;
}

/// What saving [files] removes, merged into [changes], a PATCH of an item
/// or a stock row: its photo, and the values of its attachment attributes.
void addFileRemovals(Json changes, Iterable<FormFile> files) {
  for (final f in files.where((f) => f.removing)) {
    if (f.isPhoto) {
      changes['photo'] = null;
    } else {
      final values = {...?changes['values'] as Map<String, Object?>?};
      values[f.attribute!.name] = null;
      changes['values'] = values;
    }
  }
}

/// Uploads the files chosen in [files] to the item or stock row at [owner]
/// (/items/{id} or /stock/{id}), one after the other; what wasn't
/// uploaded, each with why.
Future<List<String>> uploadFormFiles(
  ApiClient client,
  String owner,
  Iterable<FormFile> files,
) async {
  final failed = <String>[];
  for (final f in files) {
    final picked = f.picked;
    if (picked == null) continue;
    try {
      final bytes = await picked.$2();
      if (f.isPhoto) {
        await client.uploadPhoto(owner, name: picked.$1, bytes: bytes);
      } else {
        await client.uploadFile(
          owner,
          f.attribute!.name,
          name: picked.$1,
          bytes: bytes,
        );
      }
    } catch (e) {
      failed.add('${f.label} (${errorText(e)})');
    }
  }
  return failed;
}

/// A [FormFile]'s line on a form: what it has, or what saving will do, and
/// a menu to choose a file, take a photo, fetch one from an address, or
/// remove it. A tap chooses a file.
class FormFileTile extends StatefulWidget {
  const FormFileTile(this.file, {super.key, this.enabled = true});

  final FormFile file;
  final bool enabled;

  @override
  State<FormFileTile> createState() => _FormFileTileState();
}

class _FormFileTileState extends State<FormFileTile> {
  FormFile get _f => widget.file;

  void _pick(PickedFile? picked) {
    if (picked == null || !mounted) return;
    setState(() {
      _f.picked = picked;
      _f.removing = false;
    });
  }

  Future<void> _choose() async =>
      _pick(await pickUploadFile(image: _f.isPhoto));

  Future<void> _fetch() async {
    final url = await askUrl(
      context,
      title: _f.isPhoto ? 'Fetch a photo' : 'Fetch ${_f.label}',
    );
    if (url == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    showMessage(context, 'Fetching from ${url.host}…');
    try {
      final file = await fetchUrlFile(url);
      messenger.hideCurrentSnackBar();
      _pick(file);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      if (mounted) showError(context, e);
    }
  }

  void _remove() => setState(() {
    _f.picked = null;
    _f.removing = _f.current != null;
  });

  void _keep() => setState(() {
    _f.picked = null;
    _f.removing = false;
  });

  @override
  Widget build(BuildContext context) {
    final f = _f;
    final what = f.isPhoto ? 'photo' : 'file';
    final media = f.attribute?.media ?? const [];
    final subtitle = switch (f) {
      FormFile(picked: (final name, _)) => '$name, sent when saved',
      FormFile(removing: true) => 'Removed when saved',
      FormFile(current: _?) => 'Has a $what',
      _ => [
        'No $what',
        if (media.isNotEmpty) 'Takes ${media.join(', ')}',
      ].join('. '),
    };
    final icon = f.isPhoto ? Icons.photo_outlined : attributeIcon(f.attribute!);
    final current = f.current;
    final camera = f.takesImages && canTakePhoto(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: widget.enabled,
      leading: f.picked != null
          ? PhotoOrIcon(
              null,
              icon: f.isPhoto
                  ? Icons.add_photo_alternate_outlined
                  : Icons.upload_file,
            )
          : current != null && !f.removing
          ? _FileLeading(current, fallback: icon)
          : PhotoOrIcon(null, icon: icon),
      title: Text(f.label),
      subtitle: Text(subtitle),
      onTap: _choose,
      trailing: PopupMenuButton<String>(
        tooltip: f.label,
        enabled: widget.enabled,
        onSelected: (action) => switch (action) {
          'choose' => _choose(),
          'take' => takeCameraPhoto().then(_pick),
          'url' => _fetch(),
          'keep' => _keep(),
          _ => _remove(),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'choose',
            child: Text(f.isPhoto ? 'Choose a photo…' : 'Choose a file…'),
          ),
          if (camera)
            const PopupMenuItem(value: 'take', child: Text('Take a photo…')),
          if (canFetchUrl)
            const PopupMenuItem(value: 'url', child: Text('Fetch from URL…')),
          if (f.changed && current != null)
            PopupMenuItem(value: 'keep', child: Text('Keep the current $what')),
          if (f.picked != null || (current != null && !f.removing))
            const PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }
}
