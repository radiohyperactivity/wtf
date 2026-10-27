// The API client, the counterpart of the CLI's Go client (internal/client).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'units.dart';

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

final _unitNumber = RegExp(
  r'"(base_factor|base_offset)"\s*:\s*(-?[0-9][0-9.eE+-]*)',
);

/// Decodes an answer. Unit factors and offsets are kept as the text the
/// server wrote, because some have more digits than a double holds (°F:
/// 0.55555555555555555556), and conversions must be as exact as the CLI's.
Object? decodeBody(String text) => jsonDecode(
  text.replaceAllMapped(_unitNumber, (m) => '"${m[1]}":"${m[2]}"'),
);

/// The class tree or the location tree.
enum TreeKind {
  classes('/classes'),
  locations('/locations');

  const TreeKind(this.path);

  final String path;
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

  // Data that rarely changes, kept for the session: the trees (revalidated
  // with their ETag on every use), unit groups and units. A tree this client
  // changes is fetched again at once (see _wrote); unit groups and units
  // can't be changed through the API.
  final Map<TreeKind, Tree> _trees = {};
  final Map<String, Future<UnitGroup>> _groups = {};
  final Map<String, Future<List<Unit>>> _units = {};
  final _treeChanges = StreamController<TreeKind>.broadcast();

  /// A tree this client has changed, once its new version is in the cache;
  /// screens that show one load it again.
  Stream<TreeKind> get treeChanges => _treeChanges.stream;

  // Requests that change a tree: adding, changing (renaming, moving) and
  // deleting a class or location, grids included.
  static final _treeWrite = RegExp(r'^/(classes|locations)(/[^/]+)?$');

  // --- Session ---

  /// POST /login: logs in to the tenant of the server's hostname.
  Future<Me> login(String email, String password) async {
    final json = await _call(
      'POST',
      '/login',
      body: {'email': email, 'password': password},
    ) as Json;
    return Me.fromJson(json['account'] as Json, json['tenant'] as Json);
  }

  /// GET /me: the logged-in account and its tenant.
  Future<Me> me() async => Me.fromJson(await _call('GET', '/me') as Json);

  /// POST /logout: ends the session.
  Future<void> logout() => _call('POST', '/logout');

  /// PUT /me/password: changes the own password (and ends other sessions).
  Future<void> changePassword(String current, String newPassword) => _call(
    'PUT',
    '/me/password',
    body: {'current': current, 'new': newPassword},
  );

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

  /// What a label code belongs to; null when no such code exists.
  Future<CodeTarget?> code(String code) async {
    final normal = normalizeCode(code);
    if (normal == null) return null;
    try {
      return CodeTarget.fromJson(await _call('GET', '/codes/$normal') as Json);
    } on ApiProblem catch (e) {
      if (e.status == 404 || e.status == 400) return null;
      rethrow;
    }
  }

  // --- Items ---

  /// GET /items: items whose name, class path, text or choice values contain
  /// every word of [search].
  Future<ResultPage<ItemListed>> items({
    String? search,
    String? classId,
    int limit = 50,
    int offset = 0,
  }) async {
    final json = await _call(
      'GET',
      '/items',
      query: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'class': ?classId,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return ResultPage.fromJson(json as Json, ItemListed.fromJson);
  }

  Future<ItemDetail> item(String id) async =>
      ItemDetail.fromJson(await _call('GET', '/items/$id') as Json);

  /// [values] are keyed by attribute id, in the API's types (see [parseValue]).
  Future<ItemDetail> createItem({
    required String classId,
    required String name,
    String? unitGroupId,
    Map<String, Object?> values = const {},
  }) async => ItemDetail.fromJson(
    await _call(
      'POST',
      '/items',
      body: {
        'class': classId,
        'name': name,
        'unit_group': ?unitGroupId,
        if (values.isNotEmpty) 'values': values,
      },
    ) as Json,
  );

  /// PATCH /items/{id} with any of name, class and unit_group.
  Future<ItemDetail> patchItem(String id, Map<String, Object?> changes) async =>
      ItemDetail.fromJson(
        await _call('PATCH', '/items/$id', body: changes) as Json,
      );

  Future<void> deleteItem(String id) => _call('DELETE', '/items/$id');

  Future<ItemDetail> setItemValue(
    String id,
    String attributeId,
    Object? value,
  ) async => ItemDetail.fromJson(
    await _call('PUT', '/items/$id/values/$attributeId', body: {'value': value})
        as Json,
  );

  Future<ItemDetail> deleteItemValue(String id, String attributeId) async =>
      ItemDetail.fromJson(
        await _call('DELETE', '/items/$id/values/$attributeId') as Json,
      );

  // --- Stock ---

  /// GET /stock: rows of one item, or at a location and everything below it.
  Future<ResultPage<Stock>> stockList({
    String? itemId,
    String? locationId,
    int limit = 100,
    int offset = 0,
  }) async {
    final json = await _call(
      'GET',
      '/stock',
      query: {
        'item': ?itemId,
        'location': ?locationId,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return ResultPage.fromJson(json as Json, Stock.fromJson);
  }

  Future<Stock> stock(String id) async =>
      Stock.fromJson(await _call('GET', '/stock/$id') as Json);

  /// [quantity] null is uncounted; [values] are the per-unit values.
  Future<Stock> createStock({
    required String itemId,
    required String locationId,
    Decimal? quantity,
    Map<String, Object?> values = const {},
  }) async => Stock.fromJson(
    await _call(
      'POST',
      '/stock',
      body: {
        'item': itemId,
        'location': locationId,
        'quantity': ?quantity,
        if (values.isNotEmpty) 'values': values,
      },
    ) as Json,
  );

  /// PATCH /stock/{id} with any of item, location and quantity (null: uncounted).
  Future<Stock> patchStock(String id, Map<String, Object?> changes) async =>
      Stock.fromJson(await _call('PATCH', '/stock/$id', body: changes) as Json);

  /// Moves all of a row, or [quantity] of it, to another location.
  Future<Stock> moveStock(
    String id,
    String locationId, {
    Decimal? quantity,
  }) async => Stock.fromJson(
    await _call(
      'POST',
      '/stock/$id/move',
      body: {'location': locationId, 'quantity': ?quantity},
    ) as Json,
  );

  Future<void> deleteStock(String id) => _call('DELETE', '/stock/$id');

  Future<Stock> setStockValue(
    String id,
    String attributeId,
    Object? value,
  ) async => Stock.fromJson(
    await _call('PUT', '/stock/$id/values/$attributeId', body: {'value': value})
        as Json,
  );

  Future<Stock> deleteStockValue(String id, String attributeId) async =>
      Stock.fromJson(
        await _call('DELETE', '/stock/$id/values/$attributeId') as Json,
      );

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
        'parent': ?parentId,
        if (container) 'container': true,
        if (grid != null)
          'grid': {
            'columns': grid.$1,
            'rows': grid.$2,
            if (confirm) 'confirm': true,
          },
      },
    ) as Json,
  );

  /// PATCH /locations/{id} with any of name, parent (null: a root) and container.
  Future<Location> patchLocation(
    String id,
    Map<String, Object?> changes,
  ) async => Location.fromJson(
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
      body: {
        'name': name,
        'parent': ?parentId,
        if (container) 'container': true,
      },
    ) as Json,
  );

  /// PATCH /classes/{id} with any of name, parent (null: a root) and container.
  Future<ClassDetail> patchClass(
    String id,
    Map<String, Object?> changes,
  ) async => ClassDetail.fromJson(
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

  /// Assigns an attribute to a class, replacing an assignment: options left
  /// out are reset, as in the CLI.
  Future<ClassDetail> assignAttribute(
    String classId,
    String attributeId, {
    Object? defaultValue,
    bool perUnit = false,
    bool required = false,
  }) async => ClassDetail.fromJson(
    await _call(
      'PUT',
      '/classes/$classId/attributes/$attributeId',
      body: {
        'default': defaultValue,
        'per_unit': perUnit,
        'required': required,
      },
    ) as Json,
  );

  Future<ClassDetail> unassignAttribute(
    String classId,
    String attributeId,
  ) async => ClassDetail.fromJson(
    await _call('DELETE', '/classes/$classId/attributes/$attributeId') as Json,
  );

  // --- Attributes and units ---

  Future<List<Attribute>> attributes() async =>
      (await _call('GET', '/attributes') as List)
          .cast<Json>()
          .map(Attribute.fromJson)
          .toList();

  /// One attribute, with the options of a choice attribute.
  Future<Attribute> attribute(String id) async =>
      Attribute.fromJson(await _call('GET', '/attributes/$id') as Json);

  Future<List<UnitGroup>> unitGroups() async =>
      (await _call('GET', '/unit-groups') as List)
          .cast<Json>()
          .map(UnitGroup.fromJson)
          .toList();

  /// A unit group with its units, smallest first.
  Future<UnitGroup> unitGroup(String id) =>
      _groups[id] ??= _call('GET', '/unit-groups/$id')
          .then((json) => UnitGroup.fromJson(json as Json))
          .catchError((Object e) => throw _forget(_groups, id, e));

  /// All units of a quantity.
  Future<List<Unit>> unitsOf(String quantityId) => _units[quantityId] ??=
      _call('GET', '/units', query: {'quantity': quantityId})
          .then(
            (json) => (json as List).cast<Json>().map(Unit.fromJson).toList(),
          )
          .catchError((Object e) => throw _forget(_units, quantityId, e));

  /// What numbers of a unit group may be typed in, for [parseMeasure].
  Future<UnitChoice> unitChoice(UnitGroup group) async {
    final full = await unitGroup(group.id);
    return UnitChoice(
      group: full,
      quantityUnits: await unitsOf(full.quantity.id),
      groupUnits: full.units,
    );
  }

  /// A failed lookup isn't kept, so that the next use tries again.
  Object _forget(Map<String, Object> cache, String key, Object error) {
    cache.remove(key);
    return error;
  }

  /// Creates an attribute; numbers may have a unit group (of a quantity with
  /// the same datatype).
  Future<Attribute> createAttribute({
    required String name,
    required String datatype,
    String? unitGroupId,
  }) async => Attribute.fromJson(
    await _call(
      'POST',
      '/attributes',
      body: {'name': name, 'datatype': datatype, 'unit_group': ?unitGroupId},
    ) as Json,
  );

  /// PATCH /attributes/{id} with any of name, datatype and unit_group.
  Future<Attribute> patchAttribute(
    String id,
    Map<String, Object?> changes,
  ) async => Attribute.fromJson(
    await _call('PATCH', '/attributes/$id', body: changes) as Json,
  );

  Future<void> deleteAttribute(String id) => _call('DELETE', '/attributes/$id');

  Future<NamedRef> addOption(String attributeId, String name) async =>
      NamedRef.fromJson(
        await _call(
          'POST',
          '/attributes/$attributeId/options',
          body: {'name': name},
        ) as Json,
      );

  Future<NamedRef> renameOption(String id, String name) async =>
      NamedRef.fromJson(
        await _call('PATCH', '/options/$id', body: {'name': name}) as Json,
      );

  Future<void> deleteOption(String id) => _call('DELETE', '/options/$id');

  /// The quantities, with their base units.
  Future<List<Quantity>> quantities() async =>
      (await _call('GET', '/quantities') as List)
          .cast<Json>()
          .map(Quantity.fromJson)
          .toList();

  // --- Accounts ---

  Future<List<Account>> accounts() async =>
      (await _call('GET', '/accounts') as List)
          .cast<Json>()
          .map(Account.fromJson)
          .toList();

  Future<Account> account(String id) async =>
      Account.fromJson(await _call('GET', '/accounts/$id') as Json);

  /// [privileges] by their API names (data_privilege, …); without a password
  /// the account can't log in.
  Future<Account> createAccount({
    required String email,
    String? password,
    Map<String, Privilege> privileges = const {},
  }) async => Account.fromJson(
    await _call(
      'POST',
      '/accounts',
      body: {
        'email': email,
        'password': ?password,
        for (final MapEntry(:key, :value) in privileges.entries)
          key: value.json,
      },
    ) as Json,
  );

  /// PATCH /accounts/{id} with any of email, password (null: none) and the
  /// four privileges (by their API names).
  Future<Account> patchAccount(String id, Map<String, Object?> changes) async =>
      Account.fromJson(
        await _call('PATCH', '/accounts/$id', body: changes) as Json,
      );

  /// Marks the account deleted; history keeps referring to it.
  Future<void> deleteAccount(String id) => _call('DELETE', '/accounts/$id');

  // --- History ---

  /// The kinds of objects with a history.
  static const historyKinds = {
    'items',
    'stock',
    'locations',
    'classes',
    'attributes',
    'accounts',
  };

  /// GET /{kind}/{id}/history, newest first.
  Future<ResultPage<HistoryEntry>> history(
    String kind,
    String id, {
    int limit = 100,
    int offset = 0,
  }) async {
    if (!historyKinds.contains(kind)) {
      throw InputError('There is no history of "$kind".');
    }
    final json = await _call(
      'GET',
      '/$kind/$id/history',
      query: {'limit': '$limit', 'offset': '$offset'},
    );
    return ResultPage.fromJson(json as Json, HistoryEntry.fromJson);
  }

  // --- Attachments ---

  /// PATCH /attachments/{id} with any of file_name, caption (null: none) and
  /// primary_photo (images only; replaces the object's previous one).
  Future<Attachment> patchAttachment(
    String id,
    Map<String, Object?> changes,
  ) async => Attachment.fromJson(
    await _call('PATCH', '/attachments/$id', body: changes) as Json,
  );

  /// Deletes an attachment; wtfd gc removes the file later.
  Future<void> deleteAttachment(String id) =>
      _call('DELETE', '/attachments/$id');

  /// Where an attachment's content is. Native apps send [authHeaders] with it.
  Uri attachmentUrl(String id) =>
      server.resolve('$apiPath/attachments/$id/content');

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
    return decodeBody(resp.body);
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
      req.body = encodeBody(body);
    }
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
