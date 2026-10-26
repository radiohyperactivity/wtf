import 'package:flutter/material.dart';

/// The start screen. For now a placeholder; the search comes next.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: const Center(child: Text('The search comes here.')),
    );
  }
}
