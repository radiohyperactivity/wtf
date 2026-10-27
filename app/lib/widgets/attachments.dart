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
        appBar: AppBar(title: Text(attachment.caption ?? attachment.fileName)),
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

/// The attachments of an object: images as thumbnails, other files by name.
/// With [onChanged] (when the account may change the object), each has a
/// menu to change its caption, file name or primary photo, or delete it.
class AttachmentList extends StatelessWidget {
  const AttachmentList(this.attachments, {super.key, this.onChanged});

  final List<Attachment> attachments;
  final VoidCallback? onChanged;

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
                        message: [a.fileName, ?a.caption].join('\n'),
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
                          if (a.primaryPhoto)
                            const Tooltip(
                              message: 'Primary photo',
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
            title: Text(a.fileName),
            subtitle: Text([a.contentType, a.sizeText, ?a.caption].join(' · ')),
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
          case 'edit':
            final changes = await _editDialog(context, a);
            if (changes != null && changes.isNotEmpty) {
              run(() => client.patchAttachment(a.id, changes));
            }
          case 'primary':
            run(
              () => client.patchAttachment(a.id, {
                'primary_photo': !a.primaryPhoto,
              }),
            );
          case 'delete':
            if (await confirm(context, title: 'Delete ${a.fileName}?')) {
              run(() => client.deleteAttachment(a.id));
            }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'edit',
          child: Text('Caption and file name'),
        ),
        if (a.isImage)
          PopupMenuItem(
            value: 'primary',
            child: Text(
              a.primaryPhoto
                  ? 'No longer the primary photo'
                  : 'Make it the primary photo',
            ),
          ),
        const PopupMenuItem(value: 'delete', child: Text('Delete…')),
      ],
    );
  }
}

/// The caption and file name of an attachment; returns what changed.
Future<Map<String, Object?>?> _editDialog(BuildContext context, Attachment a) {
  final caption = TextEditingController(text: a.caption ?? '');
  final name = TextEditingController(text: a.fileName);
  return showDialog<Map<String, Object?>>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: () {
        caption.dispose();
        name.dispose();
      },
      child: AlertDialog(
        title: const Text('Attachment'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: caption,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Caption'),
              ),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'File name'),
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
            onPressed: () {
              final c = caption.text.trim(), n = name.text.trim();
              Navigator.pop(context, {
                if (c != (a.caption ?? '')) 'caption': c.isEmpty ? null : c,
                if (n.isNotEmpty && n != a.fileName) 'file_name': n,
              });
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
