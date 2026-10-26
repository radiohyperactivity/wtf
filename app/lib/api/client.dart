// The API client, the counterpart of the CLI's Go client (internal/client).

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// The API version and revision this app was built for.
const apiPath = '/api/v1';
const apiVersion = 1;
const apiRevision = 1;

const sessionCookie = 'wtf_session';

/// An API error: the server's problem details, or one the client makes up
/// itself (types [ApiProblem.oldServer] and [ApiProblem.unreachable]).
class ApiProblem implements Exception {
  const ApiProblem({
    required this.type,
    required this.title,
    required this.status,
    this.detail = '',
    this.supported = const [],
  });

  factory ApiProblem.fromResponse(http.Response resp) {
    ApiProblem? p;
    try {
      final json = jsonDecode(resp.body);
      if (json is Map<String, dynamic> && json['title'] is String) {
        p = ApiProblem(
          type: json['type'] as String? ?? '',
          title: json['title'] as String,
          status: json['status'] as int? ?? resp.statusCode,
          detail: json['detail'] as String? ?? '',
          supported: (json['supported'] as List?)?.cast<int>() ?? const [],
        );
      }
    } on FormatException {
      // not JSON; handled below
    }
    p ??= ApiProblem(
      type: '',
      title: resp.reasonPhrase ?? 'HTTP ${resp.statusCode}',
      status: resp.statusCode,
      detail: resp.body.trim(),
    );
    // Every answer under /api/v1 names its revision. A 404 without one, that
    // isn't the server's "unsupported API version", comes from a server that
    // doesn't know /api/v1 at all.
    if (resp.statusCode == 404 &&
        resp.headers['api-revision'] == null &&
        p.type != unsupportedVersion) {
      return const ApiProblem(
        type: oldServer,
        title: 'Not found',
        status: 404,
        detail:
            "The server doesn't serve $apiPath; it is probably older than this app: update the server (wtfd).",
      );
    }
    return p;
  }

  static const oldServer = '/problems/old-server';
  static const unreachable = '/problems/unreachable';
  static const unsupportedVersion = '/problems/unsupported-api-version';
  static const unauthenticated = '/problems/unauthenticated';

  final String type;
  final String title;
  final int status;
  final String detail;

  /// The API versions the server serves, in an unsupported-api-version problem.
  final List<int> supported;

  /// The text to show on screen.
  String get message {
    if (type == unsupportedVersion && supported.isNotEmpty) {
      return supported.last > apiVersion
          ? 'The server only serves API version ${supported.join(', ')}, newer than this app\'s ($apiVersion): update the app.'
          : 'The server only serves API version ${supported.join(', ')}, older than this app\'s ($apiVersion): update the server (wtfd).';
    }
    return detail.isEmpty ? title : '$title: $detail';
  }

  @override
  String toString() => message;
}

class ApiClient {
  /// [server] is the server's origin, such as https://wtf.example.com.
  ///
  /// With [manageCookie] the client keeps the session cookie itself, in
  /// [session], and reports changes to [onSession]: the native apps do that.
  /// In a browser the browser keeps it, and the app never sees it.
  ApiClient(
    this.server, {
    http.Client? httpClient,
    this.manageCookie = false,
    this.session,
    this.onSession,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null;

  final Uri server;
  final bool manageCookie;
  String? session;
  void Function(String? session)? onSession;

  /// The API revision of the last answer (API-Revision).
  int? serverRevision;

  final http.Client _http;
  final bool _ownsHttp;

  /// POST /login: logs in to the tenant of the server's hostname.
  Future<Me> login(String email, String password) async {
    final json = await _send('POST', '/login', {
      'email': email,
      'password': password,
    });
    return Me.fromJson(
      json['account'] as Map<String, dynamic>,
      json['tenant'] as Map<String, dynamic>,
    );
  }

  /// GET /me: the logged-in account and its tenant.
  Future<Me> me() async => Me.fromJson(await _send('GET', '/me'));

  /// POST /logout: ends the session.
  Future<void> logout() => _send('POST', '/logout');

  /// Closes the HTTP client, unless it was given to the constructor.
  void close() {
    if (_ownsHttp) _http.close();
  }

  /// Sends a request and returns the decoded JSON answer (empty for 204).
  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final req = http.Request(method, server.resolve('$apiPath$path'))
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (manageCookie && session != null) {
      req.headers['Cookie'] = '$sessionCookie=$session';
    }
    final http.Response resp;
    try {
      resp = await http.Response.fromStream(await _http.send(req));
    } on http.ClientException catch (e) {
      throw ApiProblem(
        type: ApiProblem.unreachable,
        title: "Can't reach the server",
        status: 0,
        detail: e.message,
      );
    }
    final revision = int.tryParse(resp.headers['api-revision'] ?? '');
    if (revision != null) serverRevision = revision;
    if (manageCookie) _noteCookie(resp.headers['set-cookie']);
    if (resp.statusCode >= 400) throw ApiProblem.fromResponse(resp);
    if (resp.body.isEmpty) return const {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Takes the session cookie from a Set-Cookie header. dart:io joins several
  /// Set-Cookie headers with commas; the server's cookies have no Expires
  /// (which would contain a comma), only Max-Age.
  void _noteCookie(String? header) {
    if (header == null) return;
    for (final cookie in header.split(',')) {
      final parts = cookie.split(';').map((s) => s.trim()).toList();
      if (!parts.first.startsWith('$sessionCookie=')) continue;
      final value = parts.first.substring(sessionCookie.length + 1);
      final deleted =
          value.isEmpty || parts.any((p) => p.toLowerCase() == 'max-age=0');
      final next = deleted ? null : value;
      if (next != session) {
        session = next;
        onSession?.call(next);
      }
    }
  }
}

/// The server origin from what someone typed: "wtf.example.com" becomes
/// https://wtf.example.com; a scheme given explicitly (http://…) is kept.
/// Returns null when it isn't a usable address.
Uri? serverFromInput(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.isScheme('http') && !uri.isScheme('https') ||
      uri.host.isEmpty) {
    return null;
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}
