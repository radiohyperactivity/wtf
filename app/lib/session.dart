// Who is logged in, where, and the API client for it.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/client.dart';
import 'api/models.dart';

/// Where the native apps keep the server address and the session token, and
/// every app (the web app too) the appearance.
abstract class SessionStorage {
  Future<String?> readServer();
  Future<void> writeServer(String server);
  Future<String?> readToken();
  Future<void> writeToken(String? token);
  Future<String?> readTheme();
  Future<void> writeTheme(String theme);
  Future<String?> readColour();
  Future<void> writeColour(String colour);
}

/// The server address and appearance in the settings (in a browser, its
/// local storage), the token in the system's protected storage (Keychain,
/// Keystore, Credential Manager, Secret Service).
class DeviceStorage implements SessionStorage {
  static const _serverKey = 'server';
  static const _tokenKey = 'session';
  static const _themeKey = 'theme';
  static const _colourKey = 'colour';
  final _secure = const FlutterSecureStorage();

  @override
  Future<String?> readTheme() async =>
      (await SharedPreferences.getInstance()).getString(_themeKey);

  @override
  Future<void> writeTheme(String theme) async =>
      (await SharedPreferences.getInstance()).setString(_themeKey, theme);

  @override
  Future<String?> readColour() async =>
      (await SharedPreferences.getInstance()).getString(_colourKey);

  @override
  Future<void> writeColour(String colour) async =>
      (await SharedPreferences.getInstance()).setString(_colourKey, colour);

  @override
  Future<String?> readServer() async =>
      (await SharedPreferences.getInstance()).getString(_serverKey);

  @override
  Future<void> writeServer(String server) async =>
      (await SharedPreferences.getInstance()).setString(_serverKey, server);

  @override
  Future<String?> readToken() => _secure.read(key: _tokenKey);

  @override
  Future<void> writeToken(String? token) => token == null
      ? _secure.delete(key: _tokenKey)
      : _secure.write(key: _tokenKey, value: token);
}

/// Storage for tests.
class MemoryStorage implements SessionStorage {
  MemoryStorage({this.server, this.token, this.theme, this.colour});

  String? server;
  String? token;
  String? theme;
  String? colour;

  @override
  Future<String?> readTheme() async => theme;

  @override
  Future<void> writeTheme(String theme) async => this.theme = theme;

  @override
  Future<String?> readColour() async => colour;

  @override
  Future<void> writeColour(String colour) async => this.colour = colour;

  @override
  Future<String?> readServer() async => server;

  @override
  Future<void> writeServer(String server) async => this.server = server;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String? token) async => this.token = token;
}

/// The colour the app's theme is built from, light and dark: teal, the
/// first one, or the logo's orange.
enum AppColour {
  teal('Teal'),
  orange('Orange');

  const AppColour(this.label);

  final String label;
}

class Session extends ChangeNotifier {
  /// [webOrigin] is the web app's own address: the API is there, and the
  /// browser keeps the cookie. Without it (the native apps) the server
  /// address is asked at login, and the token is kept in [storage].
  /// The HTTP client is for tests: a pretend server.
  Session({required this.storage, this.webOrigin, this._httpClient});

  final SessionStorage storage;
  final Uri? webOrigin;
  final http.Client? _httpClient;

  bool get isWeb => webOrigin != null;

  /// The server of the current or last session.
  Uri? server;

  /// The logged-in account; null when nobody is.
  Me? me;

  ApiClient? _client;

  /// Light, dark, or as the system is set (the default); kept per device,
  /// not with the account.
  ThemeMode themeMode = ThemeMode.system;

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await storage.writeTheme(mode.name);
  }

  /// The colours the app's theme is built from; kept per device too.
  AppColour colour = AppColour.teal;

  Future<void> setColour(AppColour colour) async {
    this.colour = colour;
    notifyListeners();
    await storage.writeColour(colour.name);
  }

  /// The client of the session. Only valid while someone is logged in.
  ApiClient get client => _client!;

  /// Continues the session of the last start, if it's still valid.
  Future<void> restore() async {
    themeMode =
        ThemeMode.values.asNameMap()[await storage.readTheme()] ??
        ThemeMode.system;
    colour =
        AppColour.values.asNameMap()[await storage.readColour()] ??
        AppColour.teal;
    String? token;
    if (isWeb) {
      server = webOrigin;
    } else {
      server = serverFromInput(await storage.readServer() ?? '');
      token = await storage.readToken();
      if (server == null || token == null) return;
    }
    final client = _newClient(server!, token);
    try {
      me = await client.me();
      _client = client;
    } on ApiProblem {
      // Not logged in, or the server can't be reached: log in again. A token
      // the server ended is deleted by its answer (see _newClient).
      client.close();
    }
    notifyListeners();
  }

  /// Logs in. [server] is needed in the native apps only.
  Future<void> login(String email, String password, {Uri? server}) async {
    server = isWeb ? webOrigin! : server!;
    final client = _newClient(server, null);
    try {
      me = await client.login(email, password);
    } catch (_) {
      client.close();
      rethrow;
    }
    _client?.close();
    _client = client;
    this.server = server;
    if (!isWeb) await storage.writeServer(server.toString());
    notifyListeners();
  }

  /// Logs out. Locally that always works, even if the server can't be told.
  Future<void> logout() async {
    final client = _client;
    try {
      await client?.logout();
    } on ApiProblem {
      // the session ends on the server after 30 days anyway
    }
    client?.close();
    _client = null;
    me = null;
    if (!isWeb) await storage.writeToken(null);
    notifyListeners();
  }

  /// The server answered 401: the session ended (expired, or the password
  /// was changed elsewhere). The native apps notice that by the deleted
  /// cookie; the web app, which never sees the cookie, by this.
  void ended() {
    if (me == null) return;
    me = null;
    if (!isWeb) storage.writeToken(null);
    notifyListeners();
  }

  // What the account may do; the server checks it anyway, the app only
  // hides what would be refused.
  bool get canWriteData => me?.dataPrivilege.canWrite ?? false;
  bool get canWriteModel => me?.modelPrivilege.canWrite ?? false;
  bool get canReadHistory => me?.historyPrivilege.canRead ?? false;
  bool get canReadAccounts => me?.accountPrivilege.canRead ?? false;
  bool get canWriteAccounts => me?.accountPrivilege.canWrite ?? false;

  ApiClient _newClient(Uri server, String? token) {
    late final ApiClient client;
    client = ApiClient(
      server,
      httpClient: _httpClient,
      manageCookie: !isWeb,
      session: token,
      onSession: (token) {
        storage.writeToken(token);
        // The server ended the current session (expired, or the password
        // was changed elsewhere): log in again.
        if (token == null && identical(client, _client) && me != null) {
          me = null;
          notifyListeners();
        }
      },
    );
    return client;
  }
}
