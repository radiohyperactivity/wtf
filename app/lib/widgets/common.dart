// Small pieces every screen uses: loading and errors, confirmations, paths.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/units.dart';
import '../session.dart';
import 'link.dart';

/// The text to show for an error.
String errorText(Object e) => switch (e) {
  ApiProblem p => p.message,
  InputError i => i.message,
  // dart:io's errors, by name: dart:io doesn't exist in the web app.
  _ when '$e'.startsWith('HandshakeException') =>
    "The server doesn't answer in HTTPS. If it runs without (wtfd speaks "
        'plain HTTP), write the address with http://.',
  _ when '$e'.contains('SocketException') =>
    "Can't reach the server. Check the address and port, and that the "
        'server listens on the network.',
  _ => '$e',
};

/// Notices an ended session (401), which sends the app to the login.
void noteError(BuildContext context, Object e) {
  if (e is ApiProblem && e.status == 401 && context.mounted) {
    context.read<Session>().ended();
  }
}

void showError(BuildContext context, Object e) {
  noteError(context, e);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(errorText(e)),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}

void showMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Asks before something is done; true when confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String action = 'Delete',
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: content ?? (message == null ? null : Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

/// Loads data for a screen, and shows a spinner, the error with "Try again",
/// or what [builder] makes of the data. [builder] gets a function that
/// loads again, for after a change; so does every event of [refreshOn].
class Loader<T> extends StatefulWidget {
  const Loader({
    super.key,
    required this.load,
    required this.builder,
    this.title = '',
    this.refreshOn,
  });

  final Future<T> Function() load;
  final Stream<Object?>? refreshOn;
  final Widget Function(
    BuildContext context,
    T data,
    Future<void> Function() reload,
  )
  builder;

  /// The app bar title while loading or after an error.
  final String title;

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;
  StreamSubscription<Object?>? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = widget.refreshOn?.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    // Only the latest of overlapping loads counts.
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      noteError(context, e);
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data != null && _error == null) {
      return Stack(
        children: [
          widget.builder(context, _data as T, _reload),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(errorText(_error!), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: _reload,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Calls [onDispose] when [child] leaves the screen. For a dialog's text
/// controllers: they must live until its closing animation is over, which
/// is after showDialog has returned.
class DisposeWith extends StatefulWidget {
  const DisposeWith({super.key, required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<DisposeWith> createState() => _DisposeWithState();
}

class _DisposeWithState extends State<DisposeWith> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Leaves a screen whose object is gone: back, or to [fallback] when the
/// screen was opened directly (a link or a reload).
void leave(BuildContext context, String fallback) {
  if (!context.mounted) return;
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(fallback);
  }
}

/// A heading inside a list.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          // At most half the row, so buttons wrap rather than overflow on
          // a phone.
          if (trailing case final trailing?) Flexible(child: trailing),
        ],
      ),
    );
  }
}

/// "Label    value" in a details list. A [link] value is a web address.
class Field extends StatelessWidget {
  const Field(
    this.label,
    this.value, {
    super.key,
    this.onTap,
    this.note,
    this.link = false,
  });

  final String label;
  final String value;
  final String? note;
  final VoidCallback? onTap;
  final bool link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: link
                  ? Wrap(
                      children: [
                        LinkText(value),
                        if (note != null)
                          Text(
                            '  $note',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    )
                  : Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: value,
                            style: onTap == null
                                ? null
                                : TextStyle(color: theme.colorScheme.primary),
                          ),
                          if (note != null)
                            TextSpan(
                              text: '  $note',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A path whose parts are links: Home / Garage / Shelf 2.
class PathLinks extends StatelessWidget {
  const PathLinks({super.key, required this.parts});

  /// Each part's name and where it leads (null: not a link).
  final List<(String, String?)> parts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, (name, target)) in parts.indexed) ...[
          if (i > 0)
            Text(
              ' / ',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          target == null
              ? Text(name)
              : InkWell(
                  onTap: () => context.push(target),
                  child: Text(
                    name,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
        ],
      ],
    );
  }
}

/// A "Missing required: …" warning.
class MissingNote extends StatelessWidget {
  const MissingNote(this.names, {super.key});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: scheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Missing required: ${names.join(', ')}',
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// A placeholder line in an empty section.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// Content no wider than is pleasant to read, centred on wide screens.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child, this.maxWidth = 840});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
