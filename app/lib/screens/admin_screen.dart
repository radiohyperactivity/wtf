import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/common.dart';
import 'model_import.dart';

/// What the inventory is set up with, rather than what it keeps: classes,
/// attributes (with their options), units and accounts; and importing and
/// exporting model files. Only admins get here (ACCOUNTS.md).
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: Readable(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('Classes'),
              subtitle: const Text(
                'What kinds of items there are, and their attributes',
              ),
              onTap: () => context.push('/classes'),
            ),
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
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Import'),
              subtitle: const Text(
                'Units, attributes and classes from a model file',
              ),
              onTap: () => importModelFile(context),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Export'),
              subtitle: const Text(
                'A class with everything below it, as a model file',
              ),
              onTap: () => exportChosenClass(context),
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Accounts'),
              subtitle: const Text('Who can log in, and their roles'),
              onTap: () => context.push('/accounts'),
            ),
          ],
        ),
      ),
    );
  }
}
