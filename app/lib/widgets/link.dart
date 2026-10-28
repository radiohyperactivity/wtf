// URL values as links: a tap opens them in the browser, a right click or a
// long press offers to open or copy them.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the browser. Tests replace it.
Future<bool> Function(Uri url) openLink = (url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// [url] as a link. A text that isn't a URL (the server only stores http and
/// https ones) is shown as it is.
class LinkText extends StatefulWidget {
  const LinkText(this.url, {super.key, this.maxLines});

  final String url;
  final int? maxLines;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  Uri? get _uri {
    final uri = Uri.tryParse(widget.url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
        ? uri
        : null;
  }

  Future<void> _open(Uri uri) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool opened;
    try {
      opened = await openLink(uri);
    } on Object {
      opened = false;
    }
    if (!opened) {
      messenger?.showSnackBar(
        SnackBar(content: Text("Couldn't open ${widget.url}")),
      );
    }
  }

  Future<void> _menu(Uri uri, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(at);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const [
        PopupMenuItem(
          value: 'open',
          child: ListTile(
            leading: Icon(Icons.open_in_new),
            title: Text('Open link'),
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          child: ListTile(leading: Icon(Icons.copy), title: Text('Copy link')),
        ),
      ],
    );
    switch (choice) {
      case 'open':
        await _open(uri);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: widget.url));
        messenger?.showSnackBar(const SnackBar(content: Text('Link copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    final text = Text(
      widget.url,
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
      style: uri == null
          ? null
          : TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
    );
    if (uri == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      // In the web app the browser's own menu would cover ours.
      onEnter: (_) {
        if (kIsWeb) BrowserContextMenu.disableContextMenu();
      },
      onExit: (_) {
        if (kIsWeb) BrowserContextMenu.enableContextMenu();
      },
      // No tooltip: on a phone it would take the long press.
      child: GestureDetector(
        onTap: () => _open(uri),
        onSecondaryTapUp: (d) => _menu(uri, d.globalPosition),
        onLongPressStart: (d) => _menu(uri, d.globalPosition),
        child: text,
      ),
    );
  }
}
