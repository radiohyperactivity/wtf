// Photos and other attached files.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/units.dart';
import '../session.dart';
import 'common.dart';
import 'link.dart';
import 'open_native.dart' if (dart.library.js_interop) 'open_native_web.dart';

/// An attached image, loaded from the API with the session. With [decode]
/// it is decoded to fit that box (in logical pixels, an infinite side being
/// no limit) instead of at full size, so a phone photo shown small doesn't
/// take tens of megabytes of memory.
class AttachmentImage extends StatelessWidget {
  const AttachmentImage(
    this.attachment, {
    super.key,
    this.fit = BoxFit.cover,
    this.size,
    this.decode,
  });

  final Attachment attachment;
  final BoxFit fit;
  final double? size;
  final Size? decode;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    ImageProvider image = NetworkImage(
      client.attachmentUrl(attachment).toString(),
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

/// The small version of an image, as lists show an object's photo.
class Thumbnail extends StatelessWidget {
  const Thumbnail(this.attachment, {super.key, this.size = 48});

  final Attachment attachment;
  final double size;

  // Cropped to a square, so decoded to twice the size: the shorter side of
  // an image up to twice as long as wide still covers it sharply.
  @override
  Widget build(BuildContext context) => _Framed(
    radius: 6,
    child: AttachmentImage(
      attachment,
      size: size,
      decode: Size.square(size * 2),
    ),
  );
}

/// An object's small photo in a list, or when it has none [icon] in a frame
/// of the same size, so the names line up: attachments, items, stock rows,
/// locations and classes.
class PhotoOrIcon extends StatelessWidget {
  const PhotoOrIcon(
    this.photo, {
    super.key,
    required this.icon,
    this.size = 48,
  });

  final Attachment? photo;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = this.photo;
    if (photo != null) return Thumbnail(photo, size: size);
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

  final Attachment photo;
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
          builder: (context, c) => AttachmentImage(
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

  final Attachment? photo;
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

/// The icon of an attachment that isn't shown as an image, by its type: the
/// common sub-types their own, the major types a default each, and a plain
/// file for the rest.
IconData attachmentIcon(Attachment a) => typeIcon(a.type);

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

/// Shows an image over the whole screen, to zoom into.
void showPhoto(BuildContext context, Attachment attachment) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text(attachment.title)),
        body: InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: AttachmentImage(attachment, fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}

/// The attachments of the object at [ownerPath] (/items/{id}, …), in one
/// list: images with their thumbnail, other files with an icon, [photo]
/// named ("Item photo", …). With [onChanged] (when
/// the account may change the object), files can be added (and photos taken,
/// where there is a camera). Each has a menu to download it and, with
/// [onChanged], to change its title, make it the object's photo ("Item
/// photo", … for images) or delete it.
class AttachmentList extends StatelessWidget {
  const AttachmentList(
    this.attachments, {
    super.key,
    required this.ownerPath,
    this.photo,
    this.onChanged,
  });

  final List<Attachment> attachments;
  final String ownerPath;
  final Attachment? photo;
  final VoidCallback? onChanged;

  bool _isPhoto(Attachment a) => photo?.id == a.id;

  @override
  Widget build(BuildContext context) {
    final write = onChanged != null;
    if (attachments.isEmpty && !write) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Attachments',
          trailing: write
              ? Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if (canTakePhoto(context))
                      TextButton.icon(
                        onPressed: () =>
                            takePhoto(context, ownerPath, onChanged!),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Take a photo'),
                      ),
                    TextButton.icon(
                      onPressed: () => addFiles(context, ownerPath, onChanged!),
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Add files'),
                    ),
                  ],
                )
              : null,
        ),
        for (final a in attachments)
          ListTile(
            leading: a.isImage
                ? InkWell(
                    onTap: () => showPhoto(context, a),
                    child: Thumbnail(a),
                  )
                : PhotoOrIcon(null, icon: attachmentIcon(a)),
            title: Text(a.title),
            subtitle: Text(
              [
                if (_isPhoto(a)) photoName(ownerPath),
                a.type,
                a.sizeText,
              ].join(' · '),
            ),
            onTap: () => context.push(attachmentRoute(a)),
            trailing: _menu(context, a),
          ),
      ],
    );
  }

  Widget _menu(BuildContext context, Attachment a) {
    final client = context.read<Session>().client;
    Future<void> run(Future<void> Function() change) async {
      try {
        await change();
        onChanged!();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return PopupMenuButton<String>(
      tooltip: 'Attachment',
      iconSize: 18,
      onSelected: (action) async {
        switch (action) {
          case 'title':
            final title = await _titleDialog(context, a);
            if (title != null && title != a.title) {
              run(() => client.patchAttachment(a, title));
            }
          case 'open':
            openAttachment(context, a);
          case 'download':
            download(context, a);
          case 'photo':
            run(() => client.setPhoto(ownerPath, _isPhoto(a) ? null : a.id));
          case 'delete':
            if (await confirm(
              context,
              title: 'Delete ${a.title}?',
              message: "It can't be restored.",
            )) {
              run(() => client.deleteAttachment(a));
            }
        }
      },
      itemBuilder: (context) => [
        if (canOpen(a, web: context.read<Session>().isWeb))
          const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuItem(value: 'download', child: Text('Download…')),
        if (onChanged != null) ...[
          const PopupMenuItem(value: 'title', child: Text('Title…')),
          if (a.isImage)
            PopupMenuItem(
              value: 'photo',
              child: Text(
                _isPhoto(a)
                    ? 'No longer the ${photoName(ownerPath).toLowerCase()}'
                    : 'Make it the ${photoName(ownerPath).toLowerCase()}',
              ),
            ),
          const PopupMenuItem(value: 'delete', child: Text('Delete…')),
        ],
      ],
    );
  }
}

/// Asks for a new title; null when cancelled.
Future<String?> _titleDialog(BuildContext context, Attachment a) {
  final title = TextEditingController(text: a.title);
  return showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: title.dispose,
      child: AlertDialog(
        title: const Text('Attachment'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            onSubmitted: (t) {
              if (t.trim().isNotEmpty) Navigator.pop(context, t.trim());
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final t = title.text.trim();
              if (t.isNotEmpty) Navigator.pop(context, t);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

/// The name of an object's photo, by the path of its object: "Item photo",
/// "Stock row photo", "Location photo" or "Class photo".
String photoName(String ownerPath) => switch (ownerPath.split('/')[1]) {
  'items' => 'Item photo',
  'stock' => 'Stock row photo',
  'locations' => 'Location photo',
  _ => 'Class photo',
};

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

/// Downloads an attachment and saves it, named after its title.
Future<void> download(BuildContext context, Attachment a) async {
  final client = context.read<Session>().client;
  final messenger = ScaffoldMessenger.of(context);
  showMessage(context, 'Downloading ${a.title}…');
  try {
    final (name, bytes) = await client.downloadAttachment(a);
    messenger.hideCurrentSnackBar();
    await saveDownloadedFile(name, bytes);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
  }
}

/// The types the native apps open with the device's own app, with their
/// extensions (the first is the one a file gets). Documents, pictures,
/// sound, video and models only: nothing that runs or may run code
/// (programs, scripts, web pages, SVG, Office files with macros, the old
/// Office formats) is opened from the app; those are Download only.
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

/// Whether Open is offered for [a]. The web app offers what the browser
/// shows itself, in a new tab: what the server sends inline (images but
/// SVG, PDF and plain text). The native apps offer [_openExtensions].
bool canOpen(Attachment a, {required bool web}) => web
    ? a.isImage || a.type == 'application/pdf' || a.type == 'text/plain'
    : _openExtensions.containsKey(a.type);

/// The name of the file the native apps open: the title, with characters
/// that file systems or shells treat specially replaced, and always ending
/// in the type's extension, so the device picks the app by the type.
String openFileName(Attachment a) {
  final extensions = _openExtensions[a.type] ?? const ['bin'];
  var stem = a.title.replaceAll(
    RegExp(r'[^\p{L}\p{N} ._()-]', unicode: true),
    '_',
  );
  final dot = stem.lastIndexOf('.');
  if (dot > 0 && extensions.contains(stem.substring(dot + 1).toLowerCase())) {
    stem = stem.substring(0, dot);
  }
  stem = stem.replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (stem.length > 100) stem = stem.substring(0, 100).trimRight();
  if (stem.isEmpty) stem = 'attachment';
  return '$stem.${extensions.first}';
}

/// Opens a downloaded attachment with the device's own app; false when
/// none opens it. Tests replace it.
Future<bool> Function(Attachment a, String name, Uint8List bytes)
openDownloadedFile = (a, name, bytes) =>
    openNative(a.hash.isEmpty ? a.id : a.hash, name, a.type, bytes);

/// Opens an attachment: the web app in a new tab of the browser, the
/// native apps with the device's own app for its type, from a copy in the
/// app's temporary files. Offered where [canOpen].
Future<void> openAttachment(BuildContext context, Attachment a) async {
  final session = context.read<Session>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bool opened;
    if (session.isWeb) {
      opened = await openLink(session.client.attachmentUrl(a));
    } else {
      showMessage(context, 'Opening ${a.title}…');
      final (_, bytes) = await session.client.downloadAttachment(a);
      opened = await openDownloadedFile(a, openFileName(a), bytes);
      messenger.hideCurrentSnackBar();
    }
    if (!opened && context.mounted) {
      showMessage(
        context,
        'Nothing on this device opens ${a.type} files. Download it instead.',
      );
    }
  } catch (e) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) showError(context, e);
  }
}

/// The app's route of an attachment: /attachment/items/{owner id}/{id}, …
String attachmentRoute(Attachment a) =>
    '/attachment${a.path.replaceFirst('/attachments/', '/')}';

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

/// Lets the user choose one or more files to attach; empty when cancelled.
/// Tests replace it.
Future<List<PickedFile>> Function() pickAttachmentFiles = () async {
  // pickFiles lets the user choose one or more.
  final files = await FilePicker.pickFiles(dialogTitle: 'Attach files');
  return [for (final f in files) (f.name, f.readAsBytes)];
};

/// Lets the user choose files and attaches them to the object at
/// [ownerPath]: one file with a title and, for an image, "make it the item
/// photo" (or class photo, …);
/// several with their file names as titles.
Future<void> addFiles(
  BuildContext context,
  String ownerPath,
  VoidCallback onChanged,
) async {
  final List<PickedFile> files;
  try {
    files = await pickAttachmentFiles();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  await _upload(context, ownerPath, files, onChanged);
}

/// Takes a photo with the camera and attaches it to the object at
/// [ownerPath].
Future<void> takePhoto(
  BuildContext context,
  String ownerPath,
  VoidCallback onChanged,
) async {
  final XFile? shot;
  try {
    shot = await ImagePicker().pickImage(source: ImageSource.camera);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (shot == null || !context.mounted) return;
  await _upload(context, ownerPath, [(shot.name, shot.readAsBytes)], onChanged);
}

Future<void> _upload(
  BuildContext context,
  String ownerPath,
  List<PickedFile> files,
  VoidCallback onChanged,
) async {
  final client = context.read<Session>().client;
  String? title;
  var photo = false;
  if (files.length == 1) {
    final options = await _uploadDialog(context, files.single.$1, ownerPath);
    if (options == null || !context.mounted) return;
    (title, photo) = options;
  }
  showMessage(
    context,
    files.length == 1 ? 'Uploading…' : 'Uploading ${files.length} files…',
  );
  final done = <String>[];
  // The result replaces "Uploading…" at once, rather than queueing behind it.
  final messenger = ScaffoldMessenger.of(context);
  try {
    for (final (name, read) in files) {
      await client.uploadAttachment(
        ownerPath,
        name: name,
        bytes: await read(),
        title: title,
        photo: photo,
      );
      done.add(name);
    }
    if (context.mounted) {
      messenger.hideCurrentSnackBar();
      showMessage(
        context,
        done.length == 1
            ? 'Attached ${done.single}.'
            : 'Attached ${done.length} files.',
      );
    }
  } catch (e) {
    if (context.mounted) {
      messenger.hideCurrentSnackBar();
      showError(
        context,
        done.isEmpty
            ? e
            : InputError('$e\nAlready attached: ${done.join(', ')}'),
      );
    }
  } finally {
    if (done.isNotEmpty) onChanged();
  }
}

/// The title of one file to upload, and whether to make it the object's
/// photo; null when cancelled.
Future<(String, bool)?> _uploadDialog(
  BuildContext context,
  String name,
  String ownerPath,
) {
  final title = TextEditingController(text: name);
  final isImage =
      (mediaTypeOf(name) ?? '').startsWith('image/') &&
      mediaTypeOf(name) != 'image/svg+xml';
  var photo = false;
  return showDialog<(String, bool)>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: title.dispose,
      child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Attach'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                if (isImage)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Make it the ${photoName(ownerPath).toLowerCase()}',
                    ),
                    value: photo,
                    onChanged: (v) => setState(() => photo = v ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (title.text.trim(), photo)),
              child: const Text('Attach'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One attachment, reached from history: its title, type and size, the
/// image itself for an image, and Restore when it is deleted.
class AttachmentScreen extends StatefulWidget {
  const AttachmentScreen({
    super.key,
    required this.ownerPath,
    required this.id,
  });

  /// /items/{id}, /stock/{id}, /locations/{id} or /classes/{id}.
  final String ownerPath;
  final String id;

  @override
  State<AttachmentScreen> createState() => _AttachmentScreenState();
}

class _AttachmentScreenState extends State<AttachmentScreen> {
  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    // Admins set up locations and classes; users keep items and stock.
    final write =
        widget.ownerPath.startsWith('/classes/') ||
            widget.ownerPath.startsWith('/locations/')
        ? session.isAdmin
        : session.canWriteItems;
    return Loader<Attachment>(
      title: 'Attachment',
      load: () => client.attachment(widget.ownerPath, widget.id),
      // Open is the main button where it's offered, with Download beside the
      // title; otherwise Download is.
      builder: (context, a, reload) => Scaffold(
        appBar: AppBar(
          title: Text(a.title),
          actions: [
            if (canOpen(a, web: session.isWeb))
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Download',
                onPressed: () => download(context, a),
              ),
          ],
        ),
        floatingActionButton: canOpen(a, web: session.isWeb)
            ? FloatingActionButton.extended(
                onPressed: () => openAttachment(context, a),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
              )
            : FloatingActionButton.extended(
                onPressed: () => download(context, a),
                icon: const Icon(Icons.download),
                label: const Text('Download'),
              ),
        body: Readable(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              if (a.deleted)
                MaterialBanner(
                  content: Text(
                    'This attachment is deleted. Restoring it brings it back '
                    'as an ordinary attachment, not as the '
                    '${photoName(widget.ownerPath).toLowerCase()} it may have been.',
                  ),
                  leading: const Icon(Icons.delete_outline),
                  actions: [
                    if (write)
                      FilledButton(
                        onPressed: () async {
                          try {
                            await client.restoreAttachment(a);
                            if (!context.mounted) return;
                            showMessage(context, 'Restored ${a.title}.');
                            await reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        child: const Text('Restore'),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              Field('Title', a.title),
              Field('Type', a.type),
              Field('Size', a.sizeText),
              if (a.isImage)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ObjectPhoto(a),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: PhotoOrIcon(null, icon: attachmentIcon(a), size: 96),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
