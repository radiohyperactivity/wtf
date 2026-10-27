import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';

/// The history of an object, newest first, like `wtf item history`. As in
/// the CLI it is shown raw: table rows, with numbers in base units.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.kind,
    required this.id,
    this.title,
  });

  /// items, stock, locations or classes.
  final String kind;
  final String id;
  final String? title;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _pageSize = 100;
  final List<HistoryEntry> _rows = [];
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
      if (!mounted) return;
      setState(() {
        _rows.addAll(page.rows);
        _total = page.total;
      });
    } catch (e) {
      if (!mounted) return;
      noteError(context, e);
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title == null ? 'History' : 'History of ${widget.title}',
        ),
      ),
      body: Readable(
        child: ListView.builder(
          itemCount: _rows.length + 1,
          itemBuilder: (context, i) {
            if (i == _rows.length) {
              if (_error != null) {
                return Column(
                  children: [
                    EmptyNote(errorText(_error!)),
                    TextButton(
                      onPressed: _more,
                      child: const Text('Try again'),
                    ),
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
                    child: Text('Show more (${_total - _rows.length} left)'),
                  ),
                );
              }
              return const SizedBox(height: 24);
            }
            final h = _rows[i];
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${h.operation} ${h.table} ${h.subject}',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text('${_when(h.happenedAt)}  ·  ${h.who}', style: muted),
                  for (final c in h.changes)
                    Text(
                      '  $c',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
