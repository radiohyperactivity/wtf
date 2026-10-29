// The API client, the counterpart of the CLI's Go client (internal/client).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'models.dart';
import 'units.dart';

/// The API version and revision this app was built for.
const apiPath = '/api/v1';
const apiVersion = 1;
const apiRevision = 12;

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

  /// Something is deleted, or a restore of something that isn't (409).
  static const deleted = '/problems/deleted';

  final String type;
  final String title;
  final int status;
  final String detail;

  /// What to do about it, when the server knows (revision 2).
  final String hint;

  /// A restore refused because the object is in something deleted; the
  /// app then offers to restore that too, or to put it somewhere else.
  bool get intoDeleted => type == deleted && hint.contains('with_parents');

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
  // with their ETag on every use), and the unit families with their units.
  // A tree this client changes is fetched again at once (see _wrote); units
  // only change by an import (see importModel).
  final Map<TreeKind, Tree> _trees = {};
  Future<List<UnitFamily>>? _families;
  final _treeChanges = StreamController<TreeKind>.broadcast();

  /// A tree this client has changed, once its new version is in the cache;
  /// screens that show one load it again.
  Stream<TreeKind> get treeChanges => _treeChanges.stream;

  // Requests that change a tree: adding, changing (renaming, moving) and
  // deleting a class or location, grids included.
  static final _treeWrite = RegExp(r'^/(classes|locations)(/[^/]+)?$');

  // --- Session ---

  /// POST /login.
  Future<Me> login(String email, String password) async {
    final json = await _call(
      'POST',
      '/login',
      body: {'email': email, 'password': password},
    ) as Json;
    return Me.fromJson(json['account'] as Json);
  }

  /// GET /me: the logged-in account.
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
    return _trees[kind] = Tree.fromJson(
      json,
      kind.path,
      etag: resp.headers['etag'],
    );
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
  /// [where]: attribute filters as JSON, as [encodeWhere] writes them.
  Future<ResultPage<ItemListed>> items({
    String? search,
    String? classId,
    String? where,
    int limit = 50,
    int offset = 0,
  }) async {
    final json = await _call(
      'GET',
      '/items',
      query: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'class': ?classId,
        if (where != null && where != '[]') 'where': where,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return ResultPage.fromJson(json as Json, ItemListed.fromJson);
  }

  /// Attribute filters for [items], with numbers written exactly.
  static String encodeWhere(List<Map<String, Object>> filters) =>
      encodeBody(filters);

  Future<ItemDetail> item(String id) async =>
      ItemDetail.fromJson(await _call('GET', '/items/$id') as Json);

  /// [values] are keyed by attribute id, in the API's types (see [parseValue]).
  Future<ItemDetail> createItem({
    required String classId,
    required String name,
    String? unitId,
    bool unitLock = false,
    Map<String, Object?> values = const {},
  }) async => ItemDetail.fromJson(
    await _call(
      'POST',
      '/items',
      body: {
        'class': classId,
        'name': name,
        'unit': ?unitId,
        if (unitLock) 'unit_lock': true,
        if (values.isNotEmpty) 'values': values,
      },
    ) as Json,
  );

  /// PATCH /items/{id} with any of name, class, unit and unit_lock.
  Future<ItemDetail> patchItem(String id, Map<String, Object?> changes) async =>
      ItemDetail.fromJson(
        await _call('PATCH', '/items/$id', body: changes) as Json,
      );

  Future<void> deleteItem(String id) => _call('DELETE', '/items/$id');

  /// Restores a deleted item with the stock deleted together with it.
  /// [options]: name, class (another class), with_parents.
  Future<ItemDetail> restoreItem(String id, [Json options = const {}]) async =>
      ItemDetail.fromJson(
        await _call('POST', '/items/$id/restore', body: options) as Json,
      );

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

  /// Restores a deleted stock row. [options]: location, with_parents.
  Future<Stock> restoreStock(String id, [Json options = const {}]) async =>
      Stock.fromJson(
        await _call('POST', '/stock/$id/restore', body: options) as Json,
      );

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

  /// The paths of locations, by id: from the tree, or fetched for deleted
  /// ones, which aren't in it.
  Future<Map<String, String>> locationPaths(Iterable<String> ids) async {
    final locations = await tree(TreeKind.locations);
    final paths = <String, String>{};
    await Future.wait([
      for (final id in ids.toSet())
        if (locations[id] case final n?)
          Future.sync(() => paths[id] = n.path)
        else
          location(id).then(
            (l) => paths[id] = l.pathText,
            onError: (Object _) => paths[id] = 'a location',
          ),
    ]);
    return paths;
  }

  /// Restores a deleted location with what was deleted together with it.
  /// [options]: name, parent (another one; null: at the top), with_parents.
  Future<Location> restoreLocation(
    String id, [
    Json options = const {},
  ]) async => Location.fromJson(
    await _call('POST', '/locations/$id/restore', body: options) as Json,
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

  /// Restores a deleted class with what was deleted together with it.
  /// [options]: name, parent (another one; null: at the top), with_parents.
  Future<ClassDetail> restoreClass(
    String id, [
    Json options = const {},
  ]) async => ClassDetail.fromJson(
    await _call('POST', '/classes/$id/restore', body: options) as Json,
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

  /// All unit families with their units (smallest first), by quantity.
  Future<List<UnitFamily>> unitFamilies() =>
      _families ??= _call('GET', '/unit-families')
          .then(
            (json) =>
                (json as List).cast<Json>().map(UnitFamily.fromJson).toList(),
          )
          // A failed lookup isn't kept, so that the next use tries again.
          .catchError((Object e) {
            _families = null;
            throw e;
          });

  /// All units, by family.
  Future<List<Unit>> units() async => [
    for (final f in await unitFamilies()) ...f.units,
  ];

  /// POST /model/import: imports a model file (seed/model-format.md), sent
  /// as it is so that no factor loses digits; its classes go below class
  /// [parent] or at the top. With [dryRun], only tells.
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
    if (report.applied) {
      _families = null; // fetched again with the new units
      await _wrote('/classes'); // the new classes
    }
    return report;
  }

  /// GET /classes/{id}/model: the class with everything below it as a model
  /// file, indented, with its keys in the order the server wrote them.
  Future<String> exportModel(String classId) async {
    final resp = await _request('GET', '/classes/$classId/model');
    final file = jsonDecode(utf8.decode(resp.bodyBytes));
    return '${const JsonEncoder.withIndent('  ').convert(file)}\n';
  }

  /// Turns a quantity on or off for choosing units (null: back to its
  /// default). Refused (409) while attributes or items use its units.
  Future<Quantity> setQuantityAvailable(String id, bool? available) async {
    final json = await _call(
      'PATCH',
      '/quantities/$id',
      body: {'available': available},
    );
    _families = null; // their availability follows the quantity's
    return Quantity.fromJson(json as Json);
  }

  /// Turns a unit family on or off for choosing units (null: back to its
  /// default). Refused (409) while attributes or items use its units.
  Future<UnitFamily> setFamilyAvailable(String id, bool? available) async {
    final json = await _call(
      'PATCH',
      '/unit-families/$id',
      body: {'available': available},
    );
    _families = null;
    return UnitFamily.fromJson(json as Json);
  }

  /// What numbers in [unit] may be typed in, for [parseMeasure].
  Future<UnitChoice> unitChoice(Unit unit) async {
    final families = await unitFamilies();
    return UnitChoice(
      unit: unit,
      familyUnits: [
        for (final f in families)
          if (f.id == unit.familyId) ...f.units,
      ],
      // Units of families that are turned off are refused, except the
      // unit's own family, which it is already shown in.
      quantityUnits: [
        for (final f in families)
          if (f.quantity.id == unit.quantity.id &&
              (f.available || f.id == unit.familyId))
            ...f.units,
      ],
    );
  }

  /// Creates an attribute; numbers may have a unit (of a quantity with the
  /// same datatype), shown always in that unit with [unitLock].
  Future<Attribute> createAttribute({
    required String name,
    required String datatype,
    String? unitId,
    bool unitLock = false,
  }) async => Attribute.fromJson(
    await _call(
      'POST',
      '/attributes',
      body: {
        'name': name,
        'datatype': datatype,
        'unit': ?unitId,
        if (unitLock) 'unit_lock': true,
      },
    ) as Json,
  );

  /// PATCH /attributes/{id} with any of name, datatype, unit and unit_lock.
  Future<Attribute> patchAttribute(
    String id,
    Map<String, Object?> changes,
  ) async => Attribute.fromJson(
    await _call('PATCH', '/attributes/$id', body: changes) as Json,
  );

  Future<void> deleteAttribute(String id) => _call('DELETE', '/attributes/$id');

  /// Restores a deleted attribute. [options]: name.
  Future<Attribute> restoreAttribute(
    String id, [
    Json options = const {},
  ]) async => Attribute.fromJson(
    await _call('POST', '/attributes/$id/restore', body: options) as Json,
  );

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

  /// One option, also a deleted one: {id, attribute, name, deleted}.
  Future<Json> option(String id) async =>
      await _call('GET', '/options/$id') as Json;

  /// Restores a deleted option; its attribute must not be deleted.
  Future<void> restoreOption(String id) =>
      _call('POST', '/options/$id/restore', body: const {});

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

  /// The kinds whose list has a history of its own: the top level of a tree,
  /// or all attributes (added, deleted, restored).
  static const listHistoryKinds = {'locations', 'classes', 'attributes'};

  /// GET /{kind}/{id}/history, newest first; with no id, GET
  /// /{kind}/history, the history of the list.
  Future<ResultPage<HistoryEntry>> history(
    String kind,
    String? id, {
    int limit = 100,
    int offset = 0,
  }) async {
    if (!(id == null ? listHistoryKinds : historyKinds).contains(kind)) {
      throw InputError('There is no history of "$kind".');
    }
    final json = await _call(
      'GET',
      id == null ? '/$kind/history' : '/$kind/$id/history',
      query: {'limit': '$limit', 'offset': '$offset'},
    );
    return ResultPage.fromJson(json as Json, HistoryEntry.fromJson);
  }

  // --- Attachments ---

  /// Changes an attachment's title.
  Future<Attachment> patchAttachment(Attachment a, String title) async =>
      Attachment.fromJson(
        await _call('PATCH', a.path, body: {'title': title}) as Json,
        a.owner,
      );

  /// Deletes an attachment, for good.
  Future<void> deleteAttachment(Attachment a) => _call('DELETE', a.path);

  /// The attachment [id] of the object at [ownerPath], also when it is
  /// deleted.
  Future<Attachment> attachment(String ownerPath, String id) async =>
      Attachment.fromJson(
        await _call('GET', '$ownerPath/attachments/$id') as Json,
        ownerPath,
      );

  /// Uploads a file to the object at [ownerPath]: [name] is its file name,
  /// and the title unless [title] is given. With [photo] it becomes the
  /// object's photo (images only). The type comes from the name's extension
  /// when it's a known one; otherwise the server detects it.
  Future<Attachment> uploadAttachment(
    String ownerPath, {
    required String name,
    required List<int> bytes,
    String? title,
    bool photo = false,
  }) async {
    final req =
        http.MultipartRequest(
            'POST',
            server.resolve('$apiPath$ownerPath/attachments'),
          )
          ..headers['Accept'] = 'application/json'
          ..fields['photo'] = '$photo';
    if (title != null && title.trim().isNotEmpty) {
      req.fields['title'] = title.trim();
    }
    final type = mediaTypeOf(name);
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: name,
        contentType: type == null ? null : MediaType.parse(type),
      ),
    );
    final resp = await _send(req);
    return Attachment.fromJson(decodeBody(resp.body) as Json, ownerPath);
  }

  /// An attachment's content, with the file name the server gives it (its
  /// title, with an extension for its type).
  Future<(String, Uint8List)> downloadAttachment(Attachment a) async {
    final req = http.Request('GET', server.resolve('$apiPath${a.path}/content'))
      ..headers['Accept'] = '*/*';
    final resp = await _send(req);
    return (
      downloadName(resp.headers['content-disposition']) ?? a.title,
      resp.bodyBytes,
    );
  }

  /// Restores a deleted attachment, as an ordinary one.
  Future<Attachment> restoreAttachment(Attachment a) async =>
      Attachment.fromJson(
        await _call('POST', '${a.path}/restore', body: const {}) as Json,
        a.owner,
      );

  /// Makes one of an object's own image attachments its photo; null for none.
  Future<void> setPhoto(String ownerPath, String? attachmentId) =>
      _call('PATCH', ownerPath, body: {'photo': attachmentId});

  /// Where an attachment's content is. Native apps send [authHeaders] with it.
  Uri attachmentUrl(Attachment a) =>
      server.resolve('$apiPath${a.path}/content');

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
  /// before the change is reported done. A restore may bring back classes
  /// and locations too (with_parents), so it refreshes both.
  Future<void> _wrote(String path) async {
    final m = _treeWrite.firstMatch(path);
    final kinds = path.endsWith('/restore')
        ? TreeKind.values
        : [if (m != null) TreeKind.values.byName(m[1]!)];
    for (final kind in kinds) {
      try {
        await tree(kind);
      } catch (_) {
        // The change itself succeeded; the tree is fetched on its next use.
        _trees.remove(kind);
      }
      if (!_treeChanges.isClosed) _treeChanges.add(kind);
    }
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
