// The app: its screens, their URLs, and its look.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'screens/account_screens.dart';
import 'screens/attribute_screens.dart';
import 'screens/class_screen.dart';
import 'screens/history_screen.dart';
import 'screens/item_form.dart';
import 'screens/item_screen.dart';
import 'screens/location_screen.dart';
import 'screens/login_screen.dart';
import 'screens/manage_screen.dart';
import 'screens/me_screen.dart';
import 'screens/node_form.dart';
import 'screens/search_screen.dart';
import 'screens/shell.dart';
import 'screens/stock_form.dart';
import 'screens/stock_screen.dart';
import 'screens/tree_screen.dart';
import 'session.dart';

class WtfApp extends StatefulWidget {
  const WtfApp({super.key, required this.session});

  final Session session;

  @override
  State<WtfApp> createState() => _WtfAppState();
}

class _WtfAppState extends State<WtfApp> {
  late final GoRouter _router = buildRouter(widget.session);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return ChangeNotifierProvider.value(
      value: widget.session,
      child: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => MaterialApp.router(
          title: 'WtF',
          theme: ThemeData(colorSchemeSeed: seed),
          darkTheme: ThemeData(
            colorSchemeSeed: seed,
            brightness: Brightness.dark,
          ),
          themeMode: widget.session.themeMode,
          routerConfig: _router,
        ),
      ),
    );
  }
}

GoRouter buildRouter(Session session) => GoRouter(
  refreshListenable: session,
  redirect: (context, state) {
    final atLogin = state.matchedLocation == '/login';
    if (session.me == null) {
      if (atLogin) return null;
      // Back to this screen after the login.
      final from = state.uri.toString();
      return from == '/'
          ? '/login'
          : Uri(path: '/login', queryParameters: {'from': from}).toString();
    }
    if (atLogin) {
      final from = state.uri.queryParameters['from'];
      // Only paths of the app itself, never another site.
      return from != null && from.startsWith('/') && !from.startsWith('//')
          ? from
          : '/';
    }
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.matchedLocation, child: child),
      // Fixed paths ("new") come before the ones with a code or id.
      routes: [
        GoRoute(path: '/', builder: (context, state) => const SearchScreen()),
        GoRoute(path: '/me', builder: (context, state) => const MeScreen()),
        GoRoute(
          path: '/manage',
          builder: (context, state) => const ManageScreen(),
        ),

        GoRoute(
          path: '/locations',
          builder: (context, state) =>
              const TreeScreen(kind: TreeKind.locations),
        ),
        GoRoute(
          path: '/locations/new',
          builder: (context, state) => NodeFormScreen(
            NodeFormArgs.add(
              TreeKind.locations,
              parentId: state.uri.queryParameters['parent'],
            ),
          ),
        ),
        GoRoute(
          path: '/locations/:code',
          builder: (context, state) =>
              LocationScreen(code: state.pathParameters['code']!),
        ),
        GoRoute(
          path: '/locations/:code/edit',
          builder: (context, state) => NodeFormScreen(
            NodeFormArgs.edit(
              TreeKind.locations,
              state.pathParameters['code']!,
            ),
          ),
        ),

        GoRoute(
          path: '/classes',
          builder: (context, state) => const TreeScreen(kind: TreeKind.classes),
        ),
        GoRoute(
          path: '/classes/new',
          builder: (context, state) => NodeFormScreen(
            NodeFormArgs.add(
              TreeKind.classes,
              parentId: state.uri.queryParameters['parent'],
            ),
          ),
        ),
        GoRoute(
          path: '/classes/:id',
          builder: (context, state) =>
              ClassScreen(id: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/classes/:id/edit',
          builder: (context, state) => NodeFormScreen(
            NodeFormArgs.edit(TreeKind.classes, state.pathParameters['id']!),
          ),
        ),

        GoRoute(
          path: '/items/new',
          builder: (context, state) =>
              ItemFormScreen(classId: state.uri.queryParameters['class']),
        ),
        GoRoute(
          path: '/items/:code',
          builder: (context, state) =>
              ItemScreen(code: state.pathParameters['code']!),
        ),
        GoRoute(
          path: '/items/:code/edit',
          builder: (context, state) =>
              ItemFormScreen(code: state.pathParameters['code']!),
        ),

        GoRoute(
          path: '/stock/new',
          builder: (context, state) => StockFormScreen(
            itemId: state.uri.queryParameters['item'],
            locationId: state.uri.queryParameters['location'],
            then: state.uri.queryParameters['then'],
          ),
        ),
        GoRoute(
          path: '/stock/:code',
          builder: (context, state) =>
              StockScreen(code: state.pathParameters['code']!),
        ),
        GoRoute(
          path: '/stock/:code/edit',
          builder: (context, state) =>
              StockFormScreen(code: state.pathParameters['code']!),
        ),

        GoRoute(
          path: '/attributes',
          builder: (context, state) => const AttributesScreen(),
        ),
        GoRoute(
          path: '/attributes/:id',
          builder: (context, state) =>
              AttributeScreen(id: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/accounts',
          builder: (context, state) => const AccountsScreen(),
        ),
        GoRoute(
          path: '/accounts/:id',
          builder: (context, state) =>
              AccountScreen(id: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/units',
          builder: (context, state) => const UnitsScreen(),
        ),

        GoRoute(
          path: '/history/:kind/:id',
          builder: (context, state) => HistoryScreen(
            kind: state.pathParameters['kind']!,
            id: state.pathParameters['id']!,
            title: state.uri.queryParameters['title'],
          ),
        ),
      ],
    ),
  ],
);
