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

/// An attached image, loaded from the API with the session.
class AttachmentImage extends StatelessWidget {
  const AttachmentImage(
    this.attachment, {
    super.key,
    this.fit = BoxFit.cover,
    this.size,
  });

  final Attachment attachment;
  final BoxFit fit;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    return Image.network(
      client.attachmentUrl(attachment).toString(),
      headers: client.authHeaders,
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

/// The attachments of the object at [ownerPath] (/items/{id}, …): images as
/// thumbnails, other files by title, [photo] marked. With [onChanged] (when
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
    final images = attachments.where((a) => a.isImage).toList();
    final files = attachments.where((a) => !a.isImage).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Attachments',
          trailing: write
              ? Wrap(
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
        if (images.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in images)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: a.title,
                        child: InkWell(
                          onTap: () => showPhoto(context, a),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AttachmentImage(a, size: 96),
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isPhoto(a))
                            Tooltip(
                              message: photoName(ownerPath),
                              child: const Icon(Icons.star, size: 16),
                            ),
                          _menu(context, a),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
        for (final a in files)
          ListTile(
            dense: true,
            leading: const Icon(Icons.attach_file),
            title: Text(a.title),
            subtitle: Text('${a.type} · ${a.sizeText}'),
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
    final write = widget.ownerPath.startsWith('/classes/')
        ? session.canWriteModel
        : session.canWriteData;
    return Loader<Attachment>(
      title: 'Attachment',
      load: () => client.attachment(widget.ownerPath, widget.id),
      builder: (context, a, reload) => Scaffold(
        appBar: AppBar(title: Text(a.title)),
        floatingActionButton: FloatingActionButton.extended(
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
                  child: InkWell(
                    onTap: () => showPhoto(context, a),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AttachmentImage(a, fit: BoxFit.contain),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
