// Small pieces every screen uses: loading and errors, confirmations, paths.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/input.dart';
import '../session.dart';
import '../theme.dart';
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

/// Asks before something is done; true when confirmed. In the System look
/// on Apple devices, as Apple's own alert.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String action = 'Delete',
  bool destructive = true,
}) async {
  if (appleLook(context)) {
    final body = content ?? (message == null ? null : Text(message));
    final ok = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        // Material, for content made of Material's widgets.
        content: body == null
            ? null
            : Material(type: MaterialType.transparency, child: body),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: !destructive,
            isDestructiveAction: destructive,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
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

/// A switch with a title, filling a form's width: Apple's own switch in the
/// System look on Apple devices, Material's otherwise.
class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;

  /// Null makes the switch greyed out.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => appleLook(context)
      ? SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: title,
          subtitle: subtitle,
          value: value,
          onChanged: onChanged,
        )
      : SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: title,
          subtitle: subtitle,
          value: value,
          onChanged: onChanged,
        );
}

/// Asks before deleting [what] ("Delete Drill?"), saying that it can't be
/// undone, after [note] if given; true when confirmed.
Future<bool> confirmDelete(BuildContext context, String what, {String? note}) =>
    confirm(
      context,
      title: 'Delete $what?',
      message: [?note, "This can't be undone."].join('\n\n'),
    );

/// The events of all [streams], for [Loader.refreshOn]: a screen that loads
/// again on more than one kind of change.
Stream<Object?> anyOf(List<Stream<Object?>> streams) {
  final subscriptions = <StreamSubscription<Object?>>[];
  late final StreamController<Object?> merged;
  merged = StreamController<Object?>(
    onListen: () {
      for (final s in streams) {
        subscriptions.add(s.listen(merged.add));
      }
    },
    onCancel: () async {
      for (final s in subscriptions) {
        await s.cancel();
      }
    },
  );
  return merged.stream;
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
  }) : content = null;

  /// A field whose value is [content], such as a path of links.
  const Field.content(this.label, Widget this.content, {super.key})
    : value = '',
      onTap = null,
      note = null,
      link = false;

  final String label;
  final String value;
  final String? note;
  final VoidCallback? onTap;
  final bool link;
  final Widget? content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = this.content;
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
              child:
                  content ??
                  (link
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
                                    : TextStyle(
                                        color: theme.colorScheme.primary,
                                      ),
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
                        )),
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

/// A screen's details above its lists: no wider than is pleasant to read,
/// from the left, while the lists below take the whole width (decision 123).
class Details extends StatelessWidget {
  const Details({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840),
      child: child,
    ),
  );
}

/// The description of a class, item, location or stock row on its form
/// (decision 127): 4 lines at first, growing with the text up to 20, and
/// scrolling past that. Enter starts a new line; Ctrl+Enter still saves.
class DescriptionField extends StatelessWidget {
  const DescriptionField({super.key, required this.controller});

  final TextEditingController controller;

  /// What it holds, for a new one: null when it is blank.
  static String? valueOf(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Adds the change of [current] to [changes], when there is one: the
  /// text, or null removing it.
  static void addChange(
    Map<String, Object?> changes,
    TextEditingController controller,
    String? current,
  ) {
    final now = valueOf(controller);
    if (now != current) changes['description'] = now;
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.multiline,
    textInputAction: TextInputAction.newline,
    minLines: 4,
    maxLines: 20,
    decoration: const InputDecoration(
      labelText: 'Description',
      alignLabelWithHint: true,
      border: OutlineInputBorder(),
    ),
  );
}

/// Below this width (logical pixels) the app is laid out for a phone: the
/// navigation is a bottom bar, and a screen's main action a button at the
/// bottom right.
const compactWidth = 600.0;

/// The main thing to do on a screen, such as "Add stock here" (decision
/// 124): on a phone, a button at the bottom right, where the thumb reaches
/// it; on wider screens, a button in the top bar, where it covers nothing.
/// A screen puts [floating] in its Scaffold and [inBar] last among its top
/// bar's actions; only one of them shows.
class MainAction {
  const MainAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  static bool _compact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactWidth;

  Widget? floating(BuildContext context) => _compact(context)
      ? FloatingActionButton.extended(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        )
      : null;

  Widget? inBar(BuildContext context) => _compact(context)
      ? null
      : Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
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

/// Asks for one line of text; null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? Function(String text)? validate,
  String action = 'Save',
  TextInputType? keyboardType,
}) {
  final text = TextEditingController(text: initial);
  final form = GlobalKey<FormState>();
  void done(BuildContext context) {
    if (form.currentState!.validate()) Navigator.pop(context, text.text.trim());
  }

  return showDialog<String>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: text.dispose,
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: TextFormField(
              controller: text,
              autofocus: true,
              keyboardType: keyboardType,
              decoration: InputDecoration(labelText: label),
              validator: (v) =>
                  validate?.call(v ?? '') ??
                  ((v ?? '').trim().isEmpty ? 'Enter some text' : null),
              onFieldSubmitted: (_) => done(context),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: () => done(context), child: Text(action)),
        ],
      ),
    ),
  );
}
