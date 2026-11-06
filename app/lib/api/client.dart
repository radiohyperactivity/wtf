// The API client, the counterpart of the CLI's Go client (internal/client).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'input.dart';
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
    this.hint = '',
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
          hint: json['hint'] as String? ?? '',
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

  /// A label code whose item, stock row or location has been deleted (410).
  static const gone = '/problems/gone';

  final String type;
  final String title;
  final int status;
  final String detail;

  /// What to do about it, when the server knows.
  final String hint;

  /// The API versions the server serves, in an unsupported-api-version problem.
  final List<int> supported;

  /// The text to show on screen.
  String get message {
    if (type == unsupportedVersion && supported.isNotEmpty) {
      return supported.last > apiVersion
          ? 'The server only serves API version ${supported.join(', ')}, newer than this app\'s ($apiVersion): update the app.'
          : 'The server only serves API version ${supported.join(', ')}, older than this app\'s ($apiVersion): update the server (wtfd).';
    }
    final text = detail.isEmpty ? title : '$title: $detail';
    return hint.isEmpty ? text : '$text\n$hint';
  }

  @override
  String toString() => message;
}

/// The MIME type of a file, by the extension of its [name]; null when it
/// isn't one of these common ones.
String? mediaTypeOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return const {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'svg': 'image/svg+xml',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'json': 'application/json',
    'zip': 'application/zip',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'stl': 'model/stl',
    'step': 'model/step',
    'stp': 'model/step',
  }[name.substring(dot + 1).toLowerCase()];
}

/// The file name in a Content-Disposition header: filename*=utf-8''… (as
/// Go writes non-ASCII names) or filename="…"; null when there is none.
String? downloadName(String? disposition) {
  if (disposition == null) return null;
  final extended = RegExp(
    r"filename\*=utf-8''([^;]+)",
    caseSensitive: false,
  ).firstMatch(disposition);
  if (extended != null) return Uri.decodeComponent(extended[1]!);
  final plain = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
  return plain?[1];
}

/// A request body that is JSON text already, sent as it is.
class RawJson {
  const RawJson(this.text);

  final String text;
}

/// JSON for a request body. [Decimal] numbers are written exactly as they
/// are, which jsonEncode can't do (it would round them to a double).
String encodeBody(Object? body) {
  final text = JsonEncoder((o) {
    if (o is Decimal) return '\u0000${o.text}\u0000';
    throw JsonUnsupportedObjectError(o);
  }).convert(body);
  return text.replaceAllMapped(
    RegExp(r'"\\u0000([^"\\]*)\\u0000"'),
    (m) => m[1]!,
  );
}

/// The class tree or the location tree.
enum TreeKind {
  classes('/classes'),
  locations('/locations');

  const TreeKind(this.path);

  final String path;
}

/// A downloaded file: the name the server gives it (the attribute's, or
/// "Photo", with an extension for its type), its type and its content.
typedef Download = ({String name, String type, Uint8List bytes});

/// A path segment: an attribute's or a choice's name, which may have
/// spaces, slashes and the like.
String _segment(String s) => Uri.encodeComponent(s);

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

  // The trees, kept for the session and revalidated with their ETag on
  // every use. A tree this client changes is fetched again at once (see
  // _wrote).
  final Map<TreeKind, Tree> _trees = {};
  final _treeChanges = StreamController<TreeKind>.broadcast();

  /// A tree this client has changed, once its new version is in the cache;
  /// screens that show one load it again.
  Stream<TreeKind> get treeChanges => _treeChanges.stream;

  // Requests that change a tree: adding, changing (renaming, moving) and
  // deleting a class or location, grids included.
  static final _treeWrite = RegExp(r'^/(classes|locations)(/[^/]+)?$');

  // --- Session ---

  /// POST /login. [client] is what this app calls itself in the list of
  /// sessions ("WtF on Pixel 9"); the session may sit unused for [maxIdle]
  /// before it ends (null: until logging out).
  Future<Me> login(
    String email,
    String password, {
    String? client,
    Duration? maxIdle,
  }) async {
    final json = await _call(
      'POST',
      '/login',
      body: {
        'email': email,
        'password': password,
        'client': client,
        'max_idle': maxIdle?.inSeconds,
      },
    ) as Json;
    return Me.fromJson(json['account'] as Json);
  }

  /// GET /me: the logged-in account.
  Future<Me> me() async => Me.fromJson(await _call('GET', '/me') as Json);

  /// POST /logout: ends the session.
  Future<void> logout() => _call('POST', '/logout');

  /// PUT /me/password: changes the own password; with [endOtherSessions],
  /// the account's other sessions end.
  Future<void> changePassword(
    String current,
    String newPassword, {
    required bool endOtherSessions,
  }) => _call(
    'PUT',
    '/me/password',
    body: {
      'current': current,
      'new': newPassword,
      'end_other_sessions': endOtherSessions,
    },
  );

  /// The account's sessions, most recently used first.
  Future<List<SessionInfo>> sessions() async =>
      (await _call('GET', '/me/sessions') as List)
          .cast<Json>()
          .map(SessionInfo.fromJson)
          .toList();

  /// Ends one of the account's sessions; the current one is a logout.
  Future<void> endSession(String id) =>
      _call('DELETE', '/me/sessions/${_segment(id)}');

  /// Ends every session of the account but this one; how many ended.
  Future<int> endOtherSessions() async {
    final json = await _call('POST', '/me/sessions/logout-others') as Json;
    return json['ended'] as int? ?? 0;
  }

  // --- Trees ---

  /// The class or location tree; the copy from last time when unchanged.
  Future<Tree> tree(TreeKind kind) async {
    final cached = _trees[kind];
    final resp = await _request(
      'GET',
      kind.path,
      headers: {if (cached?.etag != null) 'If-None-Match': cached!.etag!},
      notModifiedOk: true,
    );
    if (resp.statusCode == 304 && cached != null) return cached;
    final json = jsonDecode(resp.body) as Json;
    if (json['unchanged'] == true && cached != null) return cached;
    return _trees[kind] = Tree.fromJson(json, etag: resp.headers['etag']);
  }

  // --- Label codes ---

  /// What a label code belongs to: [CodeGone] when it was deleted; null
  /// when no such code was ever handed out.
  Future<CodeTarget?> code(String code) async {
    final normal = normalizeCode(code);
    if (normal == null) return null;
    try {
      return CodeTarget.fromJson(await _call('GET', '/codes/$normal') as Json);
    } on ApiProblem catch (e) {
      if (e.status == 410) return CodeGone(normal);
      if (e.status == 404 || e.status == 400) return null;
      rethrow;
    }
  }

  // --- Items ---

  /// GET /items: items whose name, class path, text, url or choice values
  /// contain every word of [search], in [classId] or below. [where]:
  /// attribute filters as JSON, as [encodeWhere] writes them. [after] is
  /// the `next` of the page before.
  Future<ResultPage<ItemListed>> items({
    String? search,
    String? classId,
    String? where,
    int limit = 50,
    String? after,
  }) async {
    final json = await _call(
      'GET',
      '/items',
      query: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'class': ?classId,
        if (where != null && where != '[]') 'where': where,
        'limit': '$limit',
        'after': ?after,
      },
    );
    return ResultPage.fromJson(json as Json, ItemListed.fromJson);
  }

  /// Attribute filters for [items], with numbers written exactly.
  static String encodeWhere(List<Map<String, Object>> filters) =>
      encodeBody(filters);

  Future<ItemDetail> item(String id) async =>
      ItemDetail.fromJson(await _call('GET', '/items/$id') as Json);

  /// [unit] is what its stock is counted in (null: pieces); [values] are by
  /// attribute name, in the API's types (see parseValue). The attributes
  /// not given get their defaults.
  Future<ItemDetail> createItem({
    required String classId,
    required String name,
    String? unit,
    Values values = const {},
  }) async => ItemDetail.fromJson(
    await _call(
      'POST',
      '/items',
      body: {'class': classId, 'name': name, 'unit': unit, 'values': values},
    ) as Json,
  );

  /// PATCH /items/{id}: any of name, class, unit (null: pieces), photo
  /// (null only), values (by name, null removing one) and default (names
  /// to give their default), in one transaction.
  Future<ItemDetail> patchItem(String id, Json changes) async =>
      ItemDetail.fromJson(
        await _call('PATCH', '/items/$id', body: changes) as Json,
      );

  Future<void> deleteItem(String id) => _call('DELETE', '/items/$id');

  // --- Stock ---

  /// GET /stock: rows of one item, at a location and everything below it,
  /// or with [search] in their reference or serial; by item name.
  Future<ResultPage<Stock>> stockList({
    String? itemId,
    String? locationId,
    String? search,
    int limit = 100,
    String? after,
  }) async {
    final json = await _call(
      'GET',
      '/stock',
      query: {
        'item': ?itemId,
        'location': ?locationId,
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'limit': '$limit',
        'after': ?after,
      },
    );
    return ResultPage.fromJson(json as Json, Stock.fromJson);
  }

  Future<Stock> stock(String id) async =>
      Stock.fromJson(await _call('GET', '/stock/$id') as Json);

  /// [amount] null is uncounted; [values] are those of its stock
  /// attributes, by name.
  Future<Stock> createStock({
    required String itemId,
    required String locationId,
    Decimal? amount,
    String? reference,
    String? serial,
    Values values = const {},
  }) async => Stock.fromJson(
    await _call(
      'POST',
      '/stock',
      body: {
        'item': itemId,
        'location': locationId,
        'amount': amount,
        'reference': reference,
        'serial': serial,
        'values': values,
      },
    ) as Json,
  );

  /// PATCH /stock/{id}: any of item, location, amount (null: uncounted),
  /// reference, serial, photo (null only), values and default.
  Future<Stock> patchStock(String id, Json changes) async =>
      Stock.fromJson(await _call('PATCH', '/stock/$id', body: changes) as Json);

  /// Moves all of a row, or [amount] of it, to another location; the row
  /// at the destination.
  Future<Stock> moveStock(
    String id,
    String locationId, {
    Decimal? amount,
  }) async => Stock.fromJson(
    await _call(
      'POST',
      '/stock/$id/move',
      body: {'location': locationId, 'amount': amount},
    ) as Json,
  );

  /// Adds all of a row, or [amount] of it, to the row [into]; [resolve]
  /// says, for each difference between them, which row's to keep: {
  /// "reference": "from" | "into", "serial": …, "photo": …, "values":
  /// {name: …}}. Answers [into].
  Future<Stock> mergeStock(
    String id,
    String into, {
    Decimal? amount,
    Json? resolve,
  }) async => Stock.fromJson(
    await _call(
      'POST',
      '/stock/$id/merge',
      body: {'into': into, 'amount': amount, 'resolve': resolve},
    ) as Json,
  );

  Future<void> deleteStock(String id) => _call('DELETE', '/stock/$id');

  // --- Files ---

  /// Uploads the photo of the item or stock row at [owner] (/items/{id} or
  /// /stock/{id}); it must be an image.
  Future<void> uploadPhoto(
    String owner, {
    required String name,
    required List<int> bytes,
  }) => _upload('$owner/photo', name, bytes);

  /// Uploads the file of the attachment attribute [attribute] of the item
  /// or stock row at [owner]; refused when the attribute doesn't take its
  /// type.
  Future<void> uploadFile(
    String owner,
    String attribute, {
    required String name,
    required List<int> bytes,
  }) => _upload('$owner/files/${_segment(attribute)}', name, bytes);

  Future<void> _upload(String path, String name, List<int> bytes) async {
    final req = http.MultipartRequest('PUT', server.resolve('$apiPath$path'))
      ..headers['Accept'] = 'application/json';
    final type = mediaTypeOf(name);
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: name,
        contentType: type == null ? null : MediaType.parse(type),
      ),
    );
    await _send(req);
  }

  /// A file's content, with the name and type the server gives it.
  Future<Download> download(FileRef f) async {
    final req = http.Request('GET', fileUrl(f))..headers['Accept'] = '*/*';
    final resp = await _send(req);
    return (
      name: downloadName(resp.headers['content-disposition']) ?? f.title,
      type: (resp.headers['content-type'] ?? '').split(';').first.trim(),
      bytes: resp.bodyBytes,
    );
  }

  /// Where a file's content is. The hash makes a new file a new address, so
  /// that no cache shows the old one. Native apps send [authHeaders] with it.
  Uri fileUrl(FileRef f) => server
      .resolve('$apiPath${f.path}')
      .replace(queryParameters: {'v': f.hash});

  // --- Locations ---

  Future<Location> location(String id) async =>
      Location.fromJson(await _call('GET', '/locations/$id') as Json);

  /// Creates a location; with a grid, also a compartment per cell (A1 …),
  /// and the location becomes a container. More than [gridConfirmLimit]
  /// locations need [confirm].
  Future<Location> createLocation({
    required String name,
    String? parentId,
    bool container = false,
    (int columns, int rows)? grid,
    bool confirm = false,
  }) async => Location.fromJson(
    await _call(
      'POST',
      '/locations',
      body: {
        'name': name,
        'parent': parentId,
        'container': container,
        'grid': grid == null
            ? null
            : {
                'columns': grid.$1,
                'rows': grid.$2,
                if (confirm) 'confirm': true,
              },
      },
    ) as Json,
  );

  /// PATCH /locations/{id} with any of name, parent (null: a root) and container.
  Future<Location> patchLocation(String id, Json changes) async =>
      Location.fromJson(
        await _call('PATCH', '/locations/$id', body: changes) as Json,
      );

  /// What deleting the location and everything below it would delete.
  Future<Deletion> locationDeletion(String id, {bool force = false}) async =>
      Deletion.locations(
        await _call(
          'GET',
          '/locations/$id/deletion',
          query: {if (force) 'force': 'true'},
        ) as Json,
      );

  Future<void> deleteLocation(
    String id, {
    bool recursive = false,
    bool force = false,
  }) => _call(
    'DELETE',
    '/locations/$id',
    query: {if (recursive) 'recursive': 'true', if (force) 'force': 'true'},
  );

  /// The paths of locations, by id, from the tree.
  Future<Map<String, String>> locationPaths(Iterable<String> ids) async {
    final locations = await tree(TreeKind.locations);
    return {for (final id in ids) id: locations.pathOf(id)};
  }

  // --- Classes ---

  Future<ClassDetail> cls(String id) async =>
      ClassDetail.fromJson(await _call('GET', '/classes/$id') as Json);

  Future<ClassDetail> createClass({
    required String name,
    String? parentId,
    bool container = false,
  }) async => ClassDetail.fromJson(
    await _call(
      'POST',
      '/classes',
      body: {'name': name, 'parent': parentId, 'container': container},
    ) as Json,
  );

  /// PATCH /classes/{id} with any of name, parent (null: a root) and container.
  Future<ClassDetail> patchClass(String id, Json changes) async =>
      ClassDetail.fromJson(
        await _call('PATCH', '/classes/$id', body: changes) as Json,
      );

  /// What deleting the class and everything below it would delete.
  Future<Deletion> classDeletion(String id, {bool force = false}) async =>
      Deletion.classes(
        await _call(
          'GET',
          '/classes/$id/deletion',
          query: {if (force) 'force': 'true'},
        ) as Json,
      );

  Future<void> deleteClass(
    String id, {
    bool recursive = false,
    bool force = false,
  }) => _call(
    'DELETE',
    '/classes/$id',
    query: {if (recursive) 'recursive': 'true', if (force) 'force': 'true'},
  );

  // --- A class's attributes ---
  //
  // Each change is on the class that defines the attribute, and rewrites
  // what it must below it. With dryRun it only tells how many items and
  // stock rows it would rewrite, or is refused as the change would be.

  Future<ClassChange> _change(
    String method,
    String path, {
    Object? body,
    required bool dryRun,
  }) async => ClassChange.fromJson(
    await _call(
      method,
      path,
      query: {if (dryRun) 'dry_run': 'true'},
      body: body,
    ) as Json,
  );

  /// Adds an attribute, with the definition [a] gives: its scope, type,
  /// required, unit, default, choices, media types and order.
  Future<ClassChange> addAttribute(
    String classId,
    Attribute a, {
    bool dryRun = false,
  }) => _change(
    'POST',
    '/classes/$classId/attributes',
    body: {'name': a.name, 'definition': a.definition},
    dryRun: dryRun,
  );

  /// Changes any of required, default, unit, order and media of an
  /// attribute the class defines (null removes a default, a unit or the
  /// media types).
  Future<ClassChange> changeAttribute(
    String classId,
    String name,
    Json changes, {
    bool dryRun = false,
  }) => _change(
    'PATCH',
    '/classes/$classId/attributes/${_segment(name)}',
    body: changes,
    dryRun: dryRun,
  );

  Future<ClassChange> renameAttribute(
    String classId,
    String name,
    String newName, {
    bool dryRun = false,
  }) => _change(
    'POST',
    '/classes/$classId/attributes/${_segment(name)}/rename',
    body: {'name': newName},
    dryRun: dryRun,
  );

  /// Removes an attribute, with its values.
  Future<ClassChange> removeAttribute(
    String classId,
    String name, {
    bool dryRun = false,
  }) => _change(
    'DELETE',
    '/classes/$classId/attributes/${_segment(name)}',
    dryRun: dryRun,
  );

  Future<ClassChange> addChoice(
    String classId,
    String name,
    String choice, {
    bool dryRun = false,
  }) => _change(
    'POST',
    '/classes/$classId/attributes/${_segment(name)}/choices',
    body: {'choice': choice},
    dryRun: dryRun,
  );

  Future<ClassChange> renameChoice(
    String classId,
    String name,
    String choice,
    String newChoice, {
    bool dryRun = false,
  }) => _change(
    'POST',
    '/classes/$classId/attributes/${_segment(name)}/choices/${_segment(choice)}/rename',
    body: {'choice': newChoice},
    dryRun: dryRun,
  );

  /// Removes a choice; refused while a value has it, or while it is the
  /// default or the last one.
  Future<ClassChange> removeChoice(
    String classId,
    String name,
    String choice, {
    bool dryRun = false,
  }) => _change(
    'DELETE',
    '/classes/$classId/attributes/${_segment(name)}/choices/${_segment(choice)}',
    dryRun: dryRun,
  );

  // --- Model files ---

  /// POST /model/import: imports a model file (seed/model-format.md), sent
  /// as it is; its classes go below class [parent] or at the top. With
  /// [dryRun], only tells.
  Future<ModelImport> importModel(
    String file, {
    String? parent,
    bool dryRun = false,
  }) async {
    final json = await _call(
      'POST',
      '/model/import',
      query: {'parent': ?parent, if (dryRun) 'dry_run': 'true'},
      body: RawJson(file),
    ) as Json;
    final report = ModelImport.fromJson(json);
    if (!report.dryRun) await _wrote('/classes'); // the new classes
    return report;
  }

  /// GET /classes/{id}/model: the class with everything below it as a model
  /// file, indented, with its keys in the order the server wrote them.
  Future<String> exportModel(String classId) async {
    final resp = await _request('GET', '/classes/$classId/model');
    final file = jsonDecode(utf8.decode(resp.bodyBytes));
    return '${const JsonEncoder.withIndent('  ').convert(file)}\n';
  }

  // --- Accounts ---

  Future<List<Account>> accounts() async =>
      (await _call('GET', '/accounts') as List)
          .cast<Json>()
          .map(Account.fromJson)
          .toList();

  Future<Account> account(String id) async =>
      Account.fromJson(await _call('GET', '/accounts/$id') as Json);

  /// Without a password the account can't log in.
  Future<Account> createAccount({
    required String email,
    String? password,
    Role role = Role.viewer,
  }) async => Account.fromJson(
    await _call(
      'POST',
      '/accounts',
      body: {'email': email, 'password': password, 'role': role.json},
    ) as Json,
  );

  /// PATCH /accounts/{id} with any of email, password (null: none), role
  /// and, with a password, end_sessions.
  Future<Account> patchAccount(String id, Json changes) async =>
      Account.fromJson(
        await _call('PATCH', '/accounts/$id', body: changes) as Json,
      );

  /// Deletes the account, with its sessions.
  Future<void> deleteAccount(String id) => _call('DELETE', '/accounts/$id');

  /// The session cookie for requests made outside this client, such as
  /// images; empty on the web, where the browser sends it.
  Map<String, String> get authHeaders => manageCookie && session != null
      ? {'Cookie': '$sessionCookie=$session'}
      : const {};

  /// Closes the HTTP client, unless it was given to the constructor.
  void close() {
    _treeChanges.close();
    if (_ownsHttp) _http.close();
  }

  /// Sends a request and returns the decoded JSON answer (null for 204).
  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final resp = await _request(method, path, query: query, body: body);
    if (method != 'GET') await _wrote(path);
    if (resp.body.isEmpty) return null;
    return jsonDecode(resp.body);
  }

  /// Refreshes the cached tree a successful change at [path] has changed,
  /// before the change is reported done.
  Future<void> _wrote(String path) async {
    final m = _treeWrite.firstMatch(path);
    if (m == null) return;
    final kind = TreeKind.values.byName(m[1]!);
    try {
      await tree(kind);
    } catch (_) {
      // The change itself succeeded; the tree is fetched on its next use.
      _trees.remove(kind);
    }
    if (!_treeChanges.isClosed) _treeChanges.add(kind);
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Map<String, String> headers = const {},
    bool notModifiedOk = false,
  }) async {
    var url = server.resolve('$apiPath$path');
    if (query != null && query.isNotEmpty) {
      url = url.replace(queryParameters: query);
    }
    final req = http.Request(method, url)
      ..headers['Accept'] = 'application/json'
      ..headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = body is RawJson ? body.text : encodeBody(body);
    }
    return _send(req, notModifiedOk: notModifiedOk);
  }

  /// Sends a request with the session, and turns errors into [ApiProblem]s.
  Future<http.Response> _send(
    http.BaseRequest req, {
    bool notModifiedOk = false,
  }) async {
    req.headers.addAll(authHeaders);
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
    if (resp.statusCode >= 400 || resp.statusCode == 304 && !notModifiedOk) {
      throw ApiProblem.fromResponse(resp);
    }
    return resp;
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
