import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/history_text.dart';
import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/restore.dart';

/// The history of an object, newest first: one card per action, in words
/// (history_text.dart), under a heading per day. Lines lead to what they
/// name, deleted things included, which is how deleted things are found.
/// Tapping a card shows its entries as the server sent them, as the CLI's
/// `… history` does.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.kind, this.id, this.title});

  /// items, stock, locations, classes, attributes or accounts.
  final String kind;

  /// Null: the history of the list itself (locations, classes, attributes).
  final String? id;
  final String? title;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _pageSize = 100;
  final List<HistoryEntry> _rows = [];
  List<HistoryEvent> _events = [];
  late final HistoryNames _names = HistoryNames(context.read<Session>().client);
  final Set<int> _open = {};
  int _total = 0;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<Session>().client.history(
        widget.kind,
        widget.id,
        limit: _pageSize,
        offset: _rows.length,
      );
      await _names.load(page.rows);
      if (!mounted) return;
      setState(() {
        _rows.addAll(page.rows);
        _total = page.total;
        _events = historyEvents(
          _rows,
          _names,
          HistoryFocus(widget.kind, widget.id),
        );
      });
    } catch (e) {
      if (!mounted) return;
      noteError(context, e);
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Day headings and events, as one list.
    final children = <Object>[];
    String? day;
    for (final (i, e) in _events.indexed) {
      final d = e.happenedAt == null ? '' : dayHeading(e.happenedAt!);
      if (d != day) {
        children.add(d);
        day = d;
      }
      children.add(i);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title == null ? 'History' : 'History of ${widget.title}',
        ),
      ),
      body: Readable(
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: children.length + 1,
          itemBuilder: (context, i) {
            if (i == children.length) return _footer();
            final c = children[i];
            if (c is String) return SectionTitle(c);
            final index = c as int;
            return _EventCard(
              event: _events[index],
              open: _open.contains(index),
              onToggle: () => setState(
                () => _open.contains(index)
                    ? _open.remove(index)
                    : _open.add(index),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _footer() {
    if (_error != null) {
      return Column(
        children: [
          EmptyNote(errorText(_error!)),
          TextButton(onPressed: _more, child: const Text('Try again')),
        ],
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_rows.isEmpty) return const EmptyNote('No history.');
    if (_rows.length < _total) {
      return Center(
        child: TextButton(
          onPressed: _more,
          child: Text('Show older (${_total - _rows.length} changes left)'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.open,
    required this.onToggle,
  });

  final HistoryEvent event;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final who = event.who == null
        ? 'outside the app'
        : '${event.who}${event.whoDeleted ? ' (deleted)' : ''}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        if (event.happenedAt != null)
                          clockTime(event.happenedAt!),
                        who,
                      ].join('  ·  '),
                      style: muted,
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final line in event.lines) _Line(line),
              if (open) ...[
                const Divider(),
                for (final e in event.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: SelectableText(
                      _raw(e),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// An entry as the server sent it: table, operation, and the changes (or,
  /// for an insert or delete, the row).
  static String _raw(HistoryEntry e) {
    final body = e.operation == 'update' ? e.changes : e.data;
    return '${e.operation} ${e.table}  ${jsonEncode(body)}';
  }
}

class _Line extends StatelessWidget {
  const _Line(this.line);

  final HistoryLine line;

  @override
  Widget build(BuildContext context) {
    final link = line.link;
    final theme = Theme.of(context);
    final text = Text(
      line.text,
      style: link == null
          ? theme.textTheme.bodyMedium
          : theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: link == null
          ? text
          : InkWell(onTap: () => context.push(link), child: text),
    );
  }
}
