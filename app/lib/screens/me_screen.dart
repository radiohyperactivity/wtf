import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The logged-in account, like `wtf whoami`: email, server, role;
/// the appearance; the account's sessions (`wtf sessions list`); changing
/// the password (`wtf password`) and logging out.
class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.me;
    if (me == null) return const SizedBox.shrink(); // logging out
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Readable(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(me.email),
              subtitle: const Text('Email'),
            ),
            if (session.server case final server?)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(server.toString()),
                subtitle: const Text('Server'),
              ),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(me.role.label),
              subtitle: Text('Role: ${me.role.description.toLowerCase()}'),
            ),
            const SectionTitle('Appearance on this device'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('Follow system'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {session.themeMode},
                onSelectionChanged: (s) => session.setThemeMode(s.single),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<AppColour>(
                segments: [
                  for (final c in AppColour.values)
                    ButtonSegment(
                      value: c,
                      icon: Icon(
                        Icons.circle,
                        color: appTheme(
                          c,
                          Theme.of(context).brightness,
                        ).colorScheme.primary,
                      ),
                      label: Text(c.label),
                    ),
                ],
                selected: {session.colour},
                onSelectionChanged: (s) => session.setColour(s.single),
              ),
            ),
            const _Sessions(),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _changePassword(context),
                    icon: const Icon(Icons.password),
                    label: const Text('Change password'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: session.logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('Log out'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3 Nov 2026, 14:05", in local time.
String _when(DateTime t) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day} ${months[t.month - 1]} ${t.year}, ${two(t.hour)}:${two(t.minute)}';
}

/// The account's sessions: each device logged in, since when, last used
/// from where, and when it ends unless used. Any of them can be logged
/// out, or all but this one.
class _Sessions extends StatefulWidget {
  const _Sessions();

  @override
  State<_Sessions> createState() => _SessionsState();
}

class _SessionsState extends State<_Sessions> {
  late Future<List<SessionInfo>> _sessions = _load();

  Future<List<SessionInfo>> _load() =>
      context.read<Session>().client.sessions();

  void _reload() => setState(() {
    _sessions = _load();
  });

  Future<void> _end(SessionInfo s) async {
    final session = context.read<Session>();
    if (s.current) {
      await session.logout();
      return;
    }
    final ok = await confirm(
      context,
      title: 'Log out ${s.client ?? 'this session'}?',
      action: 'Log out',
    );
    if (!ok || !mounted) return;
    try {
      await session.client.endSession(s.id);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _endOthers() async {
    final ok = await confirm(
      context,
      title: 'Log out everywhere else?',
      message: 'Every other device logged in to this account is logged out.',
      action: 'Log out',
    );
    if (!ok || !mounted) return;
    try {
      final n = await context.read<Session>().client.endOtherSessions();
      if (!mounted) return;
      showMessage(context, 'Logged out ${count(n, 'other session')}.');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _sessions,
      builder: (context, snap) {
        final sessions = snap.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              'Sessions',
              trailing: (sessions?.length ?? 0) > 1
                  ? TextButton(
                      onPressed: _endOthers,
                      child: const Text('Log out everywhere else'),
                    )
                  : null,
            ),
            if (snap.hasError)
              EmptyNote(errorText(snap.error!))
            else if (sessions == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              )
            else
              for (final s in sessions)
                ListTile(
                  leading: Icon(
                    s.current ? Icons.smartphone : Icons.devices_other,
                  ),
                  title: Text(
                    [
                      s.client ?? 'A session',
                      if (s.current) '(this one)',
                    ].join(' '),
                  ),
                  subtitle: Text(
                    [
                      'Last used ${_when(s.lastUsed)}'
                          '${s.addresses.isEmpty ? '' : ' from ${s.addresses.first}'}',
                      'logged in ${_when(s.created)}',
                      s.expires == null
                          ? 'until logged out'
                          : 'ends ${_when(s.expires!)} unless used',
                    ].join(' · '),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.logout),
                    tooltip: 'Log out',
                    onPressed: () => _end(s),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// Changes the own password; the other sessions of the account end too,
/// unless the user chooses otherwise.
Future<void> _changePassword(BuildContext context) async {
  final client = context.read<Session>().client;
  final current = TextEditingController();
  final next = TextEditingController();
  final again = TextEditingController();
  final form = GlobalKey<FormState>();
  var endOthers = true;
  String? error;
  final done = await showDialog<bool>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: () {
        current.dispose();
        next.dispose();
        again.dispose();
      },
      child: StatefulBuilder(
        builder: (context, setState) {
          Future<void> save() async {
            if (!form.currentState!.validate()) return;
            try {
              await client.changePassword(
                current.text,
                next.text,
                endOtherSessions: endOthers,
              );
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              setState(() => error = errorText(e));
            }
          }

          return AlertDialog(
            title: const Text('Change password'),
            content: SizedBox(
              width: 380,
              child: Form(
                key: form,
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: current,
                        obscureText: true,
                        autofocus: true,
                        autofillHints: const [AutofillHints.password],
                        decoration: const InputDecoration(
                          labelText: 'Current password',
                        ),
                        validator: (v) => (v ?? '').isEmpty
                            ? 'Enter your current password'
                            : null,
                      ),
                      TextFormField(
                        controller: next,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                          labelText: 'New password',
                        ),
                        validator: (v) => (v ?? '').length < 8
                            ? 'At least 8 characters'
                            : null,
                      ),
                      TextFormField(
                        controller: again,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: const InputDecoration(
                          labelText: 'New password again',
                        ),
                        onFieldSubmitted: (_) => save(),
                        validator: (v) =>
                            v != next.text ? "The two don't match" : null,
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: endOthers,
                        onChanged: (v) => setState(() => endOthers = v!),
                        title: const Text('Log out my other devices'),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: save, child: const Text('Change')),
            ],
          );
        },
      ),
    ),
  );
  if (done == true && context.mounted) {
    showMessage(
      context,
      endOthers
          ? 'Password changed. Your other devices are logged out.'
          : 'Password changed.',
    );
  }
}
