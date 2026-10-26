import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';

/// The logged-in account: email, tenant, privileges, and logging out.
class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.me;
    if (me == null) return const SizedBox.shrink(); // logging out
    return Scaffold(
      appBar: AppBar(title: const Text('Me')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.email_outlined),
            title: Text(me.email),
            subtitle: const Text('Account'),
          ),
          ListTile(
            leading: const Icon(Icons.home_work_outlined),
            title: Text(me.tenant.name),
            subtitle: Text('Tenant, ${session.server ?? me.tenant.hostname}'),
          ),
          const Divider(),
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
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: session.logout,
                icon: const Icon(Icons.logout),
                label: const Text('Log out'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
