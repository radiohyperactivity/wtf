import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../widgets/common.dart';
import 'model_import.dart';

/// What the inventory is set up with, rather than what it keeps: attributes
/// (with their options), units and accounts; and importing model files.
class ManageScreen extends StatelessWidget {
  const ManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.me;
    if (me == null) return const SizedBox.shrink(); // logging out
    return Scaffold(
      appBar: AppBar(title: const Text('Manage')),
      body: Readable(
        child: ListView(
          children: [
            if (me.modelPrivilege.canRead)
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('Attributes'),
                subtitle: const Text(
                  'What items and stock rows can have values for',
                ),
                onTap: () => context.push('/attributes'),
              ),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Units'),
              subtitle: const Text(
                'Unit families and the units numbers can be typed in',
              ),
              onTap: () => context.push('/units'),
            ),
            // A model file holds units, attributes and classes, any of them.
            if (session.canWriteModel)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Import'),
                subtitle: const Text(
                  'Units, attributes and classes from a model file',
                ),
                onTap: () => importModelFile(context),
              ),
            if (session.canReadAccounts)
              ListTile(
                leading: const Icon(Icons.group_outlined),
                title: const Text('Accounts'),
                subtitle: const Text("Who can log in, and what they may do"),
                onTap: () => context.push('/accounts'),
              ),
          ],
        ),
      ),
    );
  }
}
