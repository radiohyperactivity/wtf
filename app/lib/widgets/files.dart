// Files of items and stock rows: their photo, and the files of attachment
// attributes (api/attachment.md). Showing, opening, saving, uploading and
// removing them.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../session.dart';
import 'common.dart';
import 'link.dart';
import 'open_native.dart' if (dart.library.js_interop) 'open_native_web.dart';

/// A photo, loaded from the API with the session. With [decode] it is
/// decoded to fit that box (in logical pixels, an infinite side being no
/// limit) instead of at full size, so a phone photo shown small doesn't
/// take tens of megabytes of memory.
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
    ImageProvider image = NetworkImage(
      client.fileUrl(file).toString(),
      headers: client.authHeaders,
    );
    if (decode case final box?) {
      final ratio = MediaQuery.devicePixelRatioOf(context);
      int? pixels(double side) => side.isFinite ? (side * ratio).ceil() : null;
      if (pixels(box.width) != null || pixels(box.height) != null) {
        image = ResizeImage(
          image,
          width: pixels(box.width),
          height: pixels(box.height),
          policy: ResizeImagePolicy.fit,
        );
      }
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
/// offer the camera for a photo upload); not desktops.
bool canTakePhoto(BuildContext context) {
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

/// The photo of the item or stock row at [owner] (/items/{id} or
/// /stock/{id}): choose an image or take one, or remove it. True when it
/// changed.
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
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(hasPhoto ? 'Another photo' : 'Choose a photo'),
            onTap: () => Navigator.pop(context, 'choose'),
          ),
          if (camera)
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'take'),
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
        final shot = await ImagePicker().pickImage(source: ImageSource.camera);
        if (shot == null || !context.mounted) return false;
        return await _upload(
          context,
          (shot.name, shot.readAsBytes),
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

/// An attachment attribute of the item or stock row at [owner]: its file,
/// if it has one, to open or save; with [onChanged] (when the account may
/// change it), to upload, replace or remove ([remove] sends the PATCH that
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

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final write = onChanged != null;
    final takes = attribute.media.isEmpty
        ? null
        : 'Takes ${attribute.media.join(', ')}';
    return ListTile(
      leading: PhotoOrIcon(null, icon: attributeIcon(attribute)),
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
