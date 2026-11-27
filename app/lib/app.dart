// The app: its screens, their URLs, and its look.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api/client.dart';
import 'camera.dart';
import 'screens/account_screens.dart';
import 'screens/admin_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/class_screen.dart';
import 'screens/item_form.dart';
import 'screens/item_screen.dart';
import 'screens/location_screen.dart';
import 'screens/login_screen.dart';
import 'screens/me_screen.dart';
import 'screens/node_form.dart';
import 'screens/search_screen.dart';
import 'screens/shell.dart';
import 'screens/stock_form.dart';
import 'screens/stock_screen.dart';
import 'screens/tree_screen.dart';
import 'session.dart';
import 'theme.dart';

class WtfApp extends StatefulWidget {
  const WtfApp({super.key, required this.session});

  final Session session;

  @override
  State<WtfApp> createState() => _WtfAppState();
}

class _WtfAppState extends State<WtfApp> {
  late final _camera = Camera(session: widget.session);
  late final GoRouter _router = buildRouter(widget.session, _camera);

  @override
  void initState() {
    super.initState();
    _camera.attach(_router);
    if (_desktop) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    if (_desktop) HardwareKeyboard.instance.removeHandler(_onKey);
    _camera.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.session),
        ChangeNotifierProvider.value(value: _camera),
      ],
      child: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => MaterialApp.router(
          title: 'WtF',
          scaffoldMessengerKey: _camera.messenger,
          theme: appTheme(widget.session.colour, Brightness.light),
          darkTheme: appTheme(widget.session.colour, Brightness.dark),
          themeMode: widget.session.themeMode,
          routerConfig: _router,
          builder: (context, child) => Actions(
            actions: {EditableTextTapOutsideIntent: _tapOutside},
            child: child!,
          ),
        ),
      ),
    );
  }

  /// A tap outside a text field ends typing in it, on phones too, where
  /// Flutter keeps the field, and the keyboard, by default: the keyboard
  /// would otherwise hide the bottom of the screen until something was
  /// searched or saved.
  final _tapOutside = CallbackAction<EditableTextTapOutsideIntent>(
    onInvoke: (intent) {
      intent.focusNode.unfocus();
      return null;
    },
  );

  /// The desktop apps have keys of their own (decision 121). A browser
  /// keeps those keys for itself, and phones have none.
  static bool get _desktop =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  /// From wherever the app is, with Ctrl (⌘ on a Mac):
  ///
  /// - F: the item search, with the cursor in its search field;
  /// - N: a new item, for an account that may add items;
  /// - Shift+L: a new location, and Shift+C a new class, for admins.
  ///
  /// Not while the app is another session's camera, and a form isn't
  /// opened again over itself.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final command = mac ? keys.isMetaPressed : keys.isControlPressed;
    if (!command || keys.isAltPressed || _camera.pairing != null) return false;
    final session = widget.session;
    final shift = keys.isShiftPressed;
    final String path;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyF when !shift && session.me != null:
        _router.go('/');
        ItemSearchScreen.focusRequests.value++;
        return true;
      case LogicalKeyboardKey.keyN when !shift && session.canWriteItems:
        path = '/items/new';
      case LogicalKeyboardKey.keyL when shift && session.isAdmin:
        path = '/locations/new';
      case LogicalKeyboardKey.keyC when shift && session.isAdmin:
        path = '/classes/new';
      default:
        return false;
    }
    final here = _router.routerDelegate.currentConfiguration.uri.path;
    if (here != path) _router.push(path);
    return true;
  }
}

/// The app's router. While the app is the camera for another session
/// ([camera]), it shows only the camera screen.
GoRouter buildRouter(Session session, Camera camera) => GoRouter(
  refreshListenable: Listenable.merge([session, camera]),
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
    final atCamera = state.matchedLocation == '/camera';
    if (camera.pairing != null) return atCamera ? null : '/camera';
    if (atCamera) return '/';
    // The server would refuse the rest of an admin screen anyway.
    if (!session.isAdmin && adminOnly(state.matchedLocation)) return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/camera', builder: (context, state) => const CameraScreen()),
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.matchedLocation, child: child),
      // Fixed paths ("new") come before the ones with a code or id.
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ItemSearchScreen(),
        ),
        GoRoute(
          path: '/found',
          builder: (context, state) {
            final q = state.uri.queryParameters;
            return FoundItemsScreen(
              key: ValueKey(state.uri.toString()),
              search: q['search'],
              classId: q['class'],
              where: q['where'],
            );
          },
        ),
        GoRoute(path: '/me', builder: (context, state) => const MeScreen()),
        GoRoute(
          path: '/admin',
          builder: (context, state) => const AdminScreen(),
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
          path: '/accounts',
          builder: (context, state) => const AccountsScreen(),
        ),
        GoRoute(
          path: '/accounts/:id',
          builder: (context, state) =>
              AccountScreen(id: state.pathParameters['id']!),
        ),
      ],
    ),
  ],
);
