// Photos and other attached files.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
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
      client.attachmentUrl(attachment.id).toString(),
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
/// the account may change the object), each has a menu to change its title,
/// make it the photo (images) or remove it.
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
    if (attachments.isEmpty) return const SizedBox.shrink();
    final images = attachments.where((a) => a.isImage).toList();
    final files = attachments.where((a) => !a.isImage).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Attachments'),
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
                            const Tooltip(
                              message: 'The photo',
                              child: Icon(Icons.star, size: 16),
                            ),
                          if (onChanged != null) _menu(context, a),
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
            subtitle: Text(a.type),
            trailing: onChanged == null ? null : _menu(context, a),
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
              run(() => client.patchAttachment(a.id, {'title': title}));
            }
          case 'photo':
            run(() => client.setPhoto(ownerPath, _isPhoto(a) ? null : a.id));
          case 'remove':
            if (await confirm(
              context,
              title: 'Remove ${a.title}?',
              message: "It can't be restored.",
              action: 'Remove',
            )) {
              run(() => client.removeAttachment(ownerPath, a.id));
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'title', child: Text('Title…')),
        if (a.isImage)
          PopupMenuItem(
            value: 'photo',
            child: Text(
              _isPhoto(a) ? 'No longer the photo' : 'Make it the photo',
            ),
          ),
        const PopupMenuItem(value: 'remove', child: Text('Remove…')),
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
