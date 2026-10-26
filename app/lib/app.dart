// The app: its screens, their URLs, and its look.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'screens/login_screen.dart';
import 'screens/me_screen.dart';
import 'screens/search_screen.dart';
import 'screens/shell.dart';
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
      child: MaterialApp.router(
        title: 'WtF',
        theme: ThemeData(colorSchemeSeed: seed),
        darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
        ),
        routerConfig: _router,
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
      routes: [
        GoRoute(path: '/', builder: (context, state) => const SearchScreen()),
        GoRoute(path: '/me', builder: (context, state) => const MeScreen()),
      ],
    ),
  ],
);
