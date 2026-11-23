// Who is logged in, where, and the API client for it.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api/client.dart';
import 'api/models.dart';
import 'client_name.dart' if (dart.library.js_interop) 'client_name_web.dart';
import 'recent.dart';

/// Where the native apps keep the server address and the session token, and
/// every app (the web app too) the appearance and the session it is the
/// camera for.
abstract class SessionStorage {
  Future<String?> readServer();
  Future<void> writeServer(String server);
  Future<String?> readToken();
  Future<void> writeToken(String? token);
  Future<String?> readTheme();
  Future<void> writeTheme(String theme);
  Future<String?> readColour();
  Future<void> writeColour(String colour);

  /// The session this one is the camera for, as JSON (CameraPairing); null
  /// for none.
  Future<String?> readCamera();
  Future<void> writeCamera(String? camera);

  /// The API revisions, the server's and the app's ("1/2"), whose
  /// difference was last confirmed for [server]; null for none.
  Future<String?> readRevisionsConfirmed(String server);
  Future<void> writeRevisionsConfirmed(String server, String revisions);
}

/// The server address and appearance in the settings (in a browser, its
/// local storage), the token in the system's protected storage (Keychain,
/// Keystore, Credential Manager, Secret Service).
class DeviceStorage implements SessionStorage {
  static const _serverKey = 'server';
  static const _tokenKey = 'session';
  static const _themeKey = 'theme';
  static const _colourKey = 'colour';
  static const _cameraKey = 'camera';

  /// Followed by the server's address.
  static const _revisionsKey = 'revisions-confirmed ';
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
  Future<String?> readCamera() async =>
      (await SharedPreferences.getInstance()).getString(_cameraKey);

  @override
  Future<void> writeCamera(String? camera) async {
    final prefs = await SharedPreferences.getInstance();
    camera == null
        ? await prefs.remove(_cameraKey)
        : await prefs.setString(_cameraKey, camera);
  }

  @override
  Future<void> writeToken(String? token) => token == null
      ? _secure.delete(key: _tokenKey)
      : _secure.write(key: _tokenKey, value: token);

  @override
  Future<String?> readRevisionsConfirmed(String server) async =>
      (await SharedPreferences.getInstance()).getString(_revisionsKey + server);

  @override
  Future<void> writeRevisionsConfirmed(String server, String revisions) async =>
      (await SharedPreferences.getInstance()).setString(
        _revisionsKey + server,
        revisions,
      );
}

/// Storage for tests.
class MemoryStorage implements SessionStorage {
  MemoryStorage({
    this.server,
    this.token,
    this.theme,
    this.colour,
    this.camera,
  });

  String? server;
  String? token;
  String? theme;
  String? colour;
  String? camera;

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
  Future<String?> readCamera() async => camera;

  @override
  Future<void> writeCamera(String? camera) async => this.camera = camera;

  @override
  Future<void> writeToken(String? token) async => this.token = token;

  /// By server address.
  final revisionsConfirmed = <String, String>{};

  @override
  Future<String?> readRevisionsConfirmed(String server) async =>
      revisionsConfirmed[server];

  @override
  Future<void> writeRevisionsConfirmed(String server, String revisions) async =>
      revisionsConfirmed[server] = revisions;
}

/// How long a session may sit unused before it ends, as the login offers
/// it; null: until logging out.
const idleChoices = <(String, Duration?)>[
  ('A day', Duration(days: 1)),
  ('A week', Duration(days: 7)),
  ('30 days', Duration(days: 30)),
  ('A year', Duration(days: 365)),
  ('Until I log out', null),
];

/// What the login offers first: 30 days.
const defaultIdle = Duration(days: 30);

/// The app's look, light and dark: System, the default, looks like the
/// platform's own apps (lib/theme.dart); Teal and Orange are Material's,
/// built from teal or the logo's orange.
enum AppColour {
  system('System'),
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

  /// The app's look; kept per device too.
  AppColour colour = AppColour.system;

  Future<void> setColour(AppColour colour) async {
    this.colour = colour;
    notifyListeners();
    await storage.writeColour(colour.name);
  }

  /// The client of the session. Only valid while someone is logged in.
  ApiClient get client => _client!;

  /// The API revision of the server's last answer; null before the first.
  int? get serverRevision => _client?.serverRevision;

  /// The revisions as the warning names them: the server's, then the app's.
  String get _revisions => '$serverRevision/$apiRevision';

  /// The revisions whose difference was confirmed for this server.
  String? _confirmed;

  /// Whether to warn that the server's API revision and the app's differ:
  /// they do, and not these two have been confirmed for this server. A
  /// change of either revision warns again.
  bool get revisionWarning =>
      serverRevision != null &&
      serverRevision != apiRevision &&
      _confirmed != _revisions;

  /// The warning was read: not shown again for this server until either
  /// revision changes.
  Future<void> confirmRevisions() async {
    final server = this.server;
    if (server == null) return;
    _confirmed = _revisions;
    notifyListeners();
    await storage.writeRevisionsConfirmed(server.toString(), _revisions);
  }

  /// What this session used and made last, for the forms' defaults; begun
  /// again at every login and logout.
  Recent recent = Recent();

  /// The account's preferences; the defaults while nobody is logged in.
  Preferences preferences = const Preferences();

  // Each request for the preferences is numbered: only the answer to the
  // latest is kept, as an earlier one may arrive after it with older ones.
  int _preferencesAsked = 0;

  /// Asks the server for the account's preferences again: after logging
  /// in, and when the event stream opens or says they changed (decision
  /// 118). A server that doesn't answer leaves them as they were.
  Future<void> refreshPreferences() async {
    final client = _client;
    if (client == null) return;
    final asked = ++_preferencesAsked;
    try {
      final answer = await client.preferences();
      if (asked != _preferencesAsked || !identical(client, _client)) return;
      preferences = answer;
      notifyListeners();
    } catch (_) {
      // Kept as they were; the next event or connection asks again.
    }
  }

  /// Changes the preferences in [patch], by their names in the API. They
  /// change here at once; if the server refuses, they are asked for again,
  /// and the error is thrown.
  Future<void> setPreferences(Json patch, Preferences shown) async {
    final client = _client;
    if (client == null) return;
    preferences = shown;
    notifyListeners();
    final asked = ++_preferencesAsked;
    try {
      final answer = await client.setPreferences(patch);
      if (asked != _preferencesAsked || !identical(client, _client)) return;
      preferences = answer;
      notifyListeners();
    } catch (_) {
      await refreshPreferences();
      rethrow;
    }
  }

  /// Continues the session of the last start, if it's still valid.
  Future<void> restore() async {
    themeMode =
        ThemeMode.values.asNameMap()[await storage.readTheme()] ??
        ThemeMode.system;
    colour =
        AppColour.values.asNameMap()[await storage.readColour()] ??
        AppColour.system;
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
      _confirmed = await storage.readRevisionsConfirmed(server.toString());
      await refreshPreferences();
    } on ApiProblem {
      // Not logged in, or the server can't be reached: log in again. A token
      // the server ended is deleted by its answer (see _newClient).
      client.close();
    }
    notifyListeners();
  }

  /// Logs in, for a session that ends after [maxIdle] unused (null: when
  /// logging out). [server] is needed in the native apps only.
  Future<void> login(
    String email,
    String password, {
    Uri? server,
    Duration? maxIdle = defaultIdle,
  }) async {
    server = isWeb ? webOrigin! : server!;
    final client = _newClient(server, null);
    try {
      me = await client.login(
        email,
        password,
        client: clientName(),
        maxIdle: maxIdle,
      );
    } catch (_) {
      client.close();
      rethrow;
    }
    _client?.close();
    _client = client;
    recent = Recent();
    preferences = const Preferences();
    await refreshPreferences();
    this.server = server;
    _confirmed = await storage.readRevisionsConfirmed(server.toString());
    if (!isWeb) await storage.writeServer(server.toString());
    notifyListeners();
  }

  /// Logs out. Locally that always works, even if the server can't be told.
  Future<void> logout() async {
    final client = _client;
    try {
      await client?.logout();
    } on ApiProblem {
      // The session ends on the server once it has sat unused long enough,
      // or can be ended from another device (Account → Sessions).
    }
    // The photos seen go too, so that whoever logs in next doesn't find
    // them on this device.
    await client?.forgetFiles();
    client?.close();
    _client = null;
    me = null;
    recent = Recent();
    preferences = const Preferences();
    if (!isWeb) await storage.writeToken(null);
    notifyListeners();
  }

  /// The server answered 401: the session ended (expired, or the password
  /// was changed elsewhere). The native apps notice that by the deleted
  /// cookie; the web app, which never sees the cookie, by this.
  void ended() {
    if (me == null) return;
    me = null;
    recent = Recent();
    preferences = const Preferences();
    if (!isWeb) storage.writeToken(null);
    notifyListeners();
  }

  // What the account's role allows (ACCOUNTS.md); the server checks it
  // anyway, the app only hides what would be refused. Every account sees
  // everything but the accounts.

  /// Users and admins: items and stock rows, with their values and files.
  bool get canWriteItems => me?.role.atLeast(Role.user) ?? false;

  /// Admins: locations, classes with their attributes, model files and
  /// accounts.
  bool get isAdmin => me?.role == Role.admin;

  ApiClient _newClient(Uri server, String? token) {
    late final ApiClient client;
    client = ApiClient(
      server,
      httpClient: _httpClient,
      manageCookie: !isWeb,
      session: token,
      // A server updated while the app runs may warn now, or no longer.
      onRevision: (_) {
        if (identical(client, _client)) notifyListeners();
      },
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
