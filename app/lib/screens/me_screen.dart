import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../widgets/common.dart';

/// The logged-in account, like `wtf whoami`: email, server, privileges;
/// the appearance; changing the password (`wtf password`) and logging out.
class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.me;
    if (me == null) return const SizedBox.shrink(); // logging out
    return Scaffold(
      appBar: AppBar(title: const Text('Me')),
      body: Readable(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(me.email),
              subtitle: const Text('Account'),
            ),
            if (session.server case final server?)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(server.toString()),
                subtitle: const Text('Server'),
              ),
            const SectionTitle('Privileges'),
            for (final (label, privilege) in [
              ('Items and stock', me.dataPrivilege),
              ('Classes and locations', me.modelPrivilege),
              ('Accounts', me.accountPrivilege),
              ('History', me.historyPrivilege),
            ])
              ListTile(
                dense: true,
                title: Text(label),
                trailing: Text(privilege.label),
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

/// Changes the own password. The server ends the account's other sessions.
Future<void> _changePassword(BuildContext context) async {
  final client = context.read<Session>().client;
  final current = TextEditingController();
  final next = TextEditingController();
  final again = TextEditingController();
  final form = GlobalKey<FormState>();
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
              await client.changePassword(current.text, next.text);
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
      'Password changed. Other sessions of this account have ended.',
    );
  }
}
