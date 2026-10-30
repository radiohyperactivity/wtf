import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../session.dart';
import '../widgets/common.dart';
import '../widgets/select_keys.dart';

/// The accounts, like `wtf account list`. Only admins get here.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Loader<List<Account>>(
      title: 'Accounts',
      load: session.client.accounts,
      builder: (context, accounts, reload) => Scaffold(
        appBar: AppBar(title: const Text('Accounts')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final created = await showAccountDialog(context);
            if (created != null && context.mounted) {
              await context.push('/accounts/${created.id}');
            }
            reload();
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('New account'),
        ),
        body: Readable(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final a in accounts)
                ListTile(
                  leading: Icon(
                    a.deleted
                        ? Icons.person_off_outlined
                        : Icons.person_outline,
                  ),
                  title: Text(a.deleted ? '${a.email} (deleted)' : a.email),
                  subtitle: Text(
                    [
                      a.role.label,
                      if (!a.hasPassword) 'no password',
                    ].join(' · '),
                  ),
                  onTap: () async {
                    await context.push('/accounts/${a.id}');
                    reload();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One account, like `wtf account get`. Only admins get here.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final client = session.client;
    return Loader<Account>(
      key: ValueKey(id),
      title: 'Account',
      load: () => client.account(id),
      builder: (context, a, reload) {
        final own = a.id == session.me?.id;
        return Scaffold(
          appBar: AppBar(
            title: Text(a.email),
            actions: [
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'History',
                onPressed: () => context.push(
                  '/history/accounts/${a.id}?title=${Uri.encodeComponent(a.email)}',
                ),
              ),
              if (!a.deleted) ...[
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit',
                  onPressed: () async {
                    if (await showAccountDialog(context, current: a) != null) {
                      reload();
                    }
                  },
                ),
                if (!own)
                  PopupMenuButton<String>(
                    onSelected: (_) async {
                      final ok = await confirm(
                        context,
                        title: 'Delete account ${a.email}?',
                        message: "It can't log in any more. History keeps referring to it, and its email can be used again.",
                      );
                      if (!ok || !context.mounted) return;
                      try {
                        await client.deleteAccount(a.id);
                        if (context.mounted) leave(context, '/accounts');
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'delete', child: Text('Delete…')),
                    ],
                  ),
              ],
            ],
          ),
          body: Readable(
            child: ListView(
              children: [
                const SizedBox(height: 8),
                Field('Email', a.email, note: own ? '(you)' : null),
                Field('Role', a.role.label),
                Field('Password', a.hasPassword ? 'set' : "none: can't log in"),
                if (a.deleted) const Field('Deleted', 'yes'),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _PasswordChange { keep, set, remove }

/// Creates an account, or changes [current], like `wtf account add` and
/// `wtf account edit`: email, role, and the password (keep, set or
/// remove). A new account is a viewer unless another role is chosen; your
/// own role can't be changed. Returns the account, or null when cancelled.
Future<Account?> showAccountDialog(BuildContext context, {Account? current}) {
  final session = context.read<Session>();
  final client = session.client;
  final email = TextEditingController(text: current?.email ?? '');
  final password = TextEditingController();
  var role = current?.role ?? Role.viewer;
  final own = current != null && current.id == session.me?.id;
  var change = current == null ? _PasswordChange.set : _PasswordChange.keep;
  String? error;
  return showDialog<Account>(
    context: context,
    builder: (context) => DisposeWith(
      onDispose: () {
        email.dispose();
        password.dispose();
      },
      child: StatefulBuilder(
        builder: (context, setState) {
          Future<void> save() async {
            final e = email.text.trim();
            if (e.isEmpty) {
              setState(() => error = 'Enter an email');
              return;
            }
            if (change == _PasswordChange.set && password.text.length < 8) {
              setState(() => error = 'A password has at least 8 characters');
              return;
            }
            try {
              final Account saved;
              if (current == null) {
                saved = await client.createAccount(
                  email: e,
                  password: password.text,
                  role: role,
                );
              } else {
                saved = await client.patchAccount(current.id, {
                  if (e != current.email) 'email': e,
                  if (role != current.role) 'role': role.json,
                  if (change == _PasswordChange.set) 'password': password.text,
                  if (change == _PasswordChange.remove) 'password': null,
                });
              }
              if (context.mounted) Navigator.pop(context, saved);
            } catch (err) {
              setState(() => error = errorText(err));
            }
          }

          return AlertDialog(
            title: Text(
              current == null ? 'New account' : 'Edit ${current.email}',
            ),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: email,
                      autofocus: current == null,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 8),
                    SelectKeys<Role>(
                      options: [for (final r in Role.values) (r, r.label)],
                      value: role,
                      onChanged: (r) {
                        if (!own) setState(() => role = r);
                      },
                      child: DropdownButtonFormField<Role>(
                        initialValue: role,
                        decoration: InputDecoration(
                          labelText: 'Role',
                          helperText: own
                              ? "You can't change your own role."
                              : role.description,
                        ),
                        items: [
                          for (final r in Role.values)
                            DropdownMenuItem(value: r, child: Text(r.label)),
                        ],
                        onChanged: own
                            ? null
                            : (r) => setState(() => role = r ?? Role.viewer),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (current != null)
                      SegmentedButton<_PasswordChange>(
                        segments: const [
                          ButtonSegment(
                            value: _PasswordChange.keep,
                            label: Text('Keep password'),
                          ),
                          ButtonSegment(
                            value: _PasswordChange.set,
                            label: Text('Set'),
                          ),
                          ButtonSegment(
                            value: _PasswordChange.remove,
                            label: Text('Remove'),
                          ),
                        ],
                        selected: {change},
                        onSelectionChanged: (s) =>
                            setState(() => change = s.first),
                      ),
                    if (change == _PasswordChange.set)
                      TextField(
                        controller: password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: InputDecoration(
                          labelText: current == null
                              ? 'Password'
                              : 'New password',
                          helperText: current == null
                              ? 'At least 8 characters.'
                              : 'At least 8 characters. It ends the account\'s sessions.',
                        ),
                      ),
                    if (change == _PasswordChange.remove)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          "Without a password the account can't log in.",
                        ),
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
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: save,
                child: Text(current == null ? 'Create' : 'Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
