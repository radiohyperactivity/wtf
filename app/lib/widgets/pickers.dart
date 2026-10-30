// Choosing things: the app's counterpart of the CLI's Tab completion and
// picker. A search field filters the candidates as you type: by substring,
// ignoring case, every word anywhere (as the item search does).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../session.dart';
import 'common.dart';

/// Whether every word of [query] is in [text], ignoring case.
bool matchesWords(String text, String query) {
  final t = text.toLowerCase();
  return query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .every(t.contains);
}

/// A candidate in a picker.
class Choice<T> {
  const Choice(
    this.value,
    this.title, {
    this.subtitle,
    this.enabled = true,
    this.icon,
  });

  final T value;
  final String title;
  final String? subtitle;
  final bool enabled;
  final IconData? icon;
}

/// Shows a list to choose from; [search] gives the candidates for what has
/// been typed, starting with [query] (typed into the field that opened it,
/// see PickerKeys). Returns the chosen value, or null when cancelled.
Future<T?> pick<T>(
  BuildContext context, {
  required String title,
  required Future<List<Choice<T>>> Function(String query) search,
  String hint = 'Search',
  String query = '',
}) => showDialog<T>(
  context: context,
  builder: (context) =>
      _PickerDialog<T>(title: title, search: search, hint: hint, query: query),
);

/// [pick] from a list that is loaded once and filtered here.
Future<T?> pickFromList<T>(
  BuildContext context, {
  required String title,
  required Future<List<Choice<T>>> Function() load,
  String query = '',
}) {
  Future<List<Choice<T>>>? all;
  return pick<T>(
    context,
    title: title,
    query: query,
    search: (q) async => (await (all ??= load()))
        .where((c) => matchesWords('${c.title} ${c.subtitle ?? ''}', q))
        .toList(),
  );
}

class _PickerDialog<T> extends StatefulWidget {
  const _PickerDialog({
    super.key,
    required this.title,
    required this.search,
    required this.hint,
    required this.query,
  });

  final String title;
  final Future<List<Choice<T>>> Function(String query) search;
  final String hint;
  final String query;

  @override
  State<_PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<_PickerDialog<T>> {
  List<Choice<T>>? _choices;
  Object? _error;
  Timer? _debounce;
  int _generation = 0;
  // Typing goes on after what was typed into the field that opened it.
  late final _query = TextEditingController.fromValue(
    TextEditingValue(
      text: widget.query,
      selection: TextSelection.collapsed(offset: widget.query.length),
    ),
  );

  @override
  void initState() {
    super.initState();
    _run(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    try {
      final choices = await widget.search(query);
      if (mounted && generation == _generation) {
        setState(() {
          _choices = choices;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = e);
    }
  }

  void _changed(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _run(query));
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    final first = choices?.where((c) => c.enabled).firstOrNull;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.hint,
                ),
                onChanged: _changed,
                // Enter takes the first candidate, as the CLI's picker does.
                onSubmitted: (_) {
                  if (first != null) Navigator.pop(context, first.value);
                },
              ),
            ),
            Flexible(
              child: _error != null
                  ? EmptyNote(errorText(_error!))
                  : choices == null
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : choices.isEmpty
                  ? const EmptyNote('Nothing matches.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: choices.length,
                      itemBuilder: (context, i) {
                        final c = choices[i];
                        return ListTile(
                          leading: c.icon == null ? null : Icon(c.icon),
                          title: Text(c.title),
                          subtitle: c.subtitle == null
                              ? null
                              : Text(c.subtitle!),
                          enabled: c.enabled,
                          onTap: () => Navigator.pop(context, c.value),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The parent "none": a node at the top level.
const topLevel = '';

/// Chooses a class or location by its path.
///
/// [forUse]: the node will hold items or stock, so containers can't be
/// chosen (they show, greyed out, so the tree stays recognisable).
/// [exclude]: nodes that can't be chosen, such as a node's own subtree when
/// it moves. [allowTopLevel] offers "(top level)", returned as [topLevel].
Future<String?> pickNode(
  BuildContext context,
  TreeKind kind, {
  String? title,
  bool forUse = false,
  Set<String> exclude = const {},
  bool allowTopLevel = false,
  String query = '',
}) {
  final client = context.read<Session>().client;
  final noun = kind == TreeKind.classes ? 'class' : 'location';
  return pickFromList<String>(
    context,
    title: title ?? 'Choose a $noun',
    query: query,
    load: () async {
      final tree = await client.tree(kind);
      return [
        if (allowTopLevel)
          const Choice(topLevel, '(top level)', icon: Icons.vertical_align_top),
        for (final n in tree.all)
          if (!exclude.contains(n.id))
            Choice(
              n.id,
              n.container ? '${n.path}/' : n.path,
              subtitle: n.code,
              enabled: !(forUse && n.container),
              icon: n.container
                  ? Icons.folder_outlined
                  : (kind == TreeKind.classes
                        ? Icons.category_outlined
                        : Icons.place_outlined),
            ),
      ];
    },
  );
}

/// Chooses an item; the server searches as you type.
Future<ItemListed?> pickItem(
  BuildContext context, {
  String title = 'Choose an item',
  String query = '',
}) {
  final client = context.read<Session>().client;
  return pick<ItemListed>(
    context,
    title: title,
    query: query,
    search: (q) async {
      final classes = await client.tree(TreeKind.classes);
      final page = await client.items(search: q, limit: 30);
      return [
        for (final i in page.rows)
          Choice(
            i,
            i.name,
            subtitle: '${i.code}  ${classes.pathOf(i.classId)}',
          ),
      ];
    },
  );
}

/// A chosen unit; [unit] null is "none" (counted, or no unit).
class PickedUnit {
  const PickedUnit(this.unit);

  final Unit? unit;
}

/// Chooses a unit of the available families, or "none" when [noneLabel] is
/// given. [quantityId] limits it to the units of one quantity, in all of
/// its families.
Future<PickedUnit?> pickUnit(
  BuildContext context, {
  String? noneLabel,
  String? quantityId,
  String query = '',
}) {
  final client = context.read<Session>().client;
  return pickFromList<PickedUnit>(
    context,
    title: 'Choose a unit',
    query: query,
    load: () async => [
      if (noneLabel != null) Choice(const PickedUnit(null), noneLabel),
      for (final f in await client.unitFamilies())
        if (f.available)
          for (final u in f.units)
            if (quantityId == null || u.quantity.id == quantityId)
              Choice(
                PickedUnit(u),
                u.symbol,
                subtitle: '${u.name} · ${u.familyName} · ${u.quantity.name}',
              ),
    ],
  );
}

/// Chooses an attribute.
Future<Attribute?> pickAttribute(
  BuildContext context, {
  Set<String> exclude = const {},
}) {
  final client = context.read<Session>().client;
  return pickFromList<Attribute>(
    context,
    title: 'Choose an attribute',
    load: () async => [
      for (final a in await client.attributes())
        if (!exclude.contains(a.id))
          Choice(a, a.name, subtitle: [a.datatype, ?a.unit?.symbol].join(', ')),
    ],
  );
}
