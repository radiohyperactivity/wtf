// The API's data, as Dart classes. Field names follow openapi/openapi.json.

import 'dart:async';
import 'dart:convert';

typedef Json = Map<String, dynamic>;

List<Json> _list(Object? o) => (o as List?)?.cast<Json>() ?? const [];
List<String> _strings(Object? o) =>
    (o as List?)?.map((s) => '$s').toList() ?? const [];

/// What an account may do (ACCOUNTS.md); each role can do what the ones
/// before it can.
enum Role {
  /// Looks at everything but the accounts.
  viewer('Viewer', 'Looks, and changes nothing'),

  /// Also keeps the items and the stock.
  user('User', 'Items and stock'),

  /// Also sets up locations, classes with their attributes, and accounts.
  admin('Admin', 'Everything, also setting up the inventory');

  const Role(this.label, this.description);

  final String label;
  final String description;

  /// As the API names it.
  String get json => name;

  /// An unknown role counts as a viewer: the server decides anyway.
  static Role parse(Object? value) =>
      values.firstWhere((r) => r.name == value, orElse: () => viewer);

  bool atLeast(Role other) => index >= other.index;
}

/// The logged-in account: GET /me, and the login answer.
class Me {
  const Me({required this.id, required this.email, required this.role});

  factory Me.fromJson(Json json) => Me(
    id: json['id'] as String,
    email: json['email'] as String,
    role: Role.parse(json['role']),
  );

  final String id;
  final String email;
  final Role role;
}

/// Which build of wtfd answers (GET /api/health): its version, when it was
/// built, and the commit it was built from. Each is null when the server
/// doesn't know it, as with a build made without scripts/build.sh.
class ServerBuild {
  const ServerBuild({this.version, this.build, this.commit, this.revision});

  factory ServerBuild.fromJson(Json json) => ServerBuild(
    version: json['version'] as String?,
    build: DateTime.tryParse(json['build'] as String? ?? '')?.toLocal(),
    commit: DateTime.tryParse(json['commit'] as String? ?? '')?.toLocal(),
    revision: json['revision'] as String?,
  );

  final String? version;
  final DateTime? build;
  final DateTime? commit;
  final String? revision;
}

/// The session this one is the camera for (PUT /me/camera): its id, as
/// GET /me/sessions gives it, and what its app calls itself.
class CameraPairing {
  const CameraPairing({required this.session, this.client});

  factory CameraPairing.fromJson(Json json) => CameraPairing(
    session: json['session'] as String,
    client: json['client'] as String?,
  );

  final String session;
  final String? client;

  Json toJson() => {'session': session, 'client': client};

  /// How the app names it: "WtF on Windows", or "the other session".
  String get label => client ?? 'the other session';
}

/// What a session has open that a photo can be for (GET /me/camera, PUT
/// /me/target): an item, a stock row or a location ([type], [id] and
/// [name]), or a new one not saved yet ([waiting]: its type); none of them
/// for nothing. With [form], the one there is open in its edit form. A
/// photo for a form, new or not, goes into the form (decision 117).
class CameraTarget {
  const CameraTarget({
    this.type,
    this.id,
    this.name,
    this.waiting,
    this.form = false,
  });

  const CameraTarget.waiting(String type) : this(waiting: type);

  factory CameraTarget.fromJson(Json json) => CameraTarget(
    type: json['type'] as String?,
    id: json['id'] as String?,
    name: json['name'] as String?,
    waiting: json['waiting'] as String?,
    form: json['form'] as bool? ?? false,
  );

  static const none = CameraTarget();

  final String? type;
  final String? id;
  final String? name;
  final String? waiting;
  final bool form;

  /// Whether a photo can be taken for it.
  bool get ready => id != null || waiting != null;

  /// Whether a photo for it goes into a form on the computer.
  bool get toForm => waiting != null || form;

  /// The same one, open in its edit form.
  CameraTarget inForm() =>
      CameraTarget(type: type, id: id, name: name, form: true);

  Json toJson() => {
    'type': ?type,
    'id': ?id,
    'name': ?name,
    'waiting': ?waiting,
    if (form) 'form': true,
  };

  /// "item", "stock row" or "location", for a type.
  static String kind(String? type) => switch (type) {
    'stock' => 'stock row',
    final t? => t,
    null => 'item',
  };

  @override
  bool operator ==(Object other) =>
      other is CameraTarget &&
      other.type == type &&
      other.id == id &&
      other.name == name &&
      other.waiting == waiting &&
      other.form == form;

  @override
  int get hashCode => Object.hash(type, id, name, waiting, form);
}

/// One event of GET /me/events: its name (camera, changed, photo, ended)
/// and its data.
class ServerEvent {
  const ServerEvent(this.name, this.data);

  final String name;
  final Json data;
}

/// Turns the lines of a server-sent event stream into its events: "event:"
/// names one, "data:" gives its JSON, an empty line ends it, and comment
/// lines (":") are skipped. Cancelling the events cancels the lines, and so
/// closes the connection.
final serverEvents = StreamTransformer<String, ServerEvent>.fromBind((lines) {
  var name = 'message';
  final data = StringBuffer();
  return lines.transform(
    StreamTransformer.fromHandlers(
      handleData: (line, sink) {
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            final decoded = jsonDecode(data.toString());
            sink.add(ServerEvent(name, decoded is Json ? decoded : const {}));
          }
          name = 'message';
          data.clear();
        } else if (line.startsWith('event:')) {
          name = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.write(line.substring(5).trim());
        }
      },
    ),
  );
});

/// This app's version ("0.1.0+1"), when it was built, and the commit it
/// was built from (its ID and time), as scripts/app-build.sh stamps them;
/// null in a build made without it, or where the commit wasn't known.
const String? appVersion = bool.hasEnvironment('WTF_VERSION')
    ? String.fromEnvironment('WTF_VERSION')
    : null;
final DateTime? appBuild = DateTime.tryParse(
  const String.fromEnvironment('WTF_BUILD'),
)?.toLocal();
const String? appCommit = String.fromEnvironment('WTF_COMMIT') == ''
    ? null
    : String.fromEnvironment('WTF_COMMIT');
final DateTime? appCommitTime = DateTime.tryParse(
  const String.fromEnvironment('WTF_COMMIT_TIME'),
)?.toLocal();

/// One of the account's sessions (GET /me/sessions): a device logged in.
class SessionInfo {
  const SessionInfo({
    required this.id,
    this.client,
    required this.created,
    required this.lastUsed,
    this.maxIdle,
    this.expires,
    this.current = false,
    this.addresses = const [],
  });

  factory SessionInfo.fromJson(Json json) => SessionInfo(
    id: json['id'] as String,
    client: json['client'] as String?,
    created: DateTime.parse(json['created'] as String).toLocal(),
    lastUsed: DateTime.parse(json['last_used'] as String).toLocal(),
    maxIdle: switch (json['max_idle']) {
      int s => Duration(seconds: s),
      _ => null,
    },
    expires: DateTime.tryParse(json['expires'] as String? ?? '')?.toLocal(),
    current: json['current'] as bool? ?? false,
    addresses: [for (final u in _list(json['usage'])) '${u['address']}'],
  );

  /// The token's hash: no way back to the token.
  final String id;

  /// What the client called itself at the login ("WtF on Pixel 9").
  final String? client;
  final DateTime created;
  final DateTime lastUsed;

  /// How long it may sit unused; null: until logging out.
  final Duration? maxIdle;
  final DateTime? expires;

  /// The session of this app.
  final bool current;

  /// Where it was used from, newest first.
  final List<String> addresses;
}

class NamedRef {
  const NamedRef(this.id, this.name);

  factory NamedRef.fromJson(Json json) =>
      NamedRef(json['id'] as String, json['name'] as String);

  final String id;
  final String name;
}

List<NamedRef> _refs(Object? json) =>
    _list(json).map(NamedRef.fromJson).toList();

/// A number written plainly: 12 rather than 12.0.
String formatNumber(num n) {
  if (n is double && n == n.truncateToDouble() && n.abs() < 1e15) {
    return n.toInt().toString();
  }
  return n.toString();
}

/// A number with the label of what it is counted in: "12 mm", or "12".
String withUnit(num n, String? unit) =>
    unit == null || unit.isEmpty ? formatNumber(n) : '${formatNumber(n)} $unit';

/// The types of attributes (api/attribute.md).
const attributeTypes = [
  'text',
  'integer',
  'decimal',
  'date',
  'boolean',
  'url',
  'choice',
  'attachment',
];

/// What a type is called on screen.
String typeLabel(String type) => switch (type) {
  'decimal' => 'number',
  'boolean' => 'yes or no',
  'url' => 'link',
  'attachment' => 'file',
  _ => type,
};

/// The names an attribute can't have: those of the fixed fields, letter
/// case ignored (api/attribute.md).
const fixedFields = {
  'id',
  'code',
  'name',
  'class',
  'unit',
  'photo',
  'item',
  'location',
  'amount',
};

/// An attribute of a class: its own, or one it inherits from the class
/// [classId] above it.
class Attribute {
  const Attribute({
    required this.name,
    this.classId = '',
    this.inherited = false,
    required this.scope,
    required this.type,
    this.required = false,
    this.unit,
    this.defaultValue,
    this.choices = const [],
    this.media = const [],
    this.order = 0,
  });

  factory Attribute.fromJson(Json json) => Attribute(
    name: json['name'] as String,
    classId: json['class'] as String? ?? '',
    inherited: json['inherited'] as bool? ?? false,
    scope: json['scope'] as String? ?? 'item',
    type: json['type'] as String,
    required: json['required'] as bool? ?? false,
    unit: json['unit'] as String?,
    defaultValue: json['default'],
    choices: _strings(json['choices']),
    media: _strings(json['media']),
    order: json['order'] as int? ?? 0,
  );

  final String name;

  /// The class that defines it.
  final String classId;
  final bool inherited;

  /// item: the value is on the item; stock: on each stock row.
  final String scope;
  final String type;
  final bool required;

  /// A label for the values ("mm"); nothing converts.
  final String? unit;
  final Object? defaultValue;

  /// A choice's texts.
  final List<String> choices;

  /// The media types an attachment takes ("image/*"); any when empty.
  final List<String> media;

  /// Its place among the class's attributes of its scope.
  final int order;

  bool get onStock => scope == 'stock';
  bool get isNumber => type == 'integer' || type == 'decimal';
  bool get isFile => type == 'attachment';

  /// The default as shown; empty when there is none.
  String get defaultText =>
      defaultValue == null ? '' : formatValue(this, defaultValue);

  /// The definition as POST /classes/{id}/attributes takes it.
  Json get definition => {
    'scope': scope,
    'type': type,
    'required': required,
    'unit': ?unit,
    'default': ?defaultValue,
    if (type == 'choice') 'choices': choices,
    if (media.isNotEmpty) 'media': media,
    // Without one, it goes last among the attributes of its scope.
    if (order > 0) 'order': order,
  };
}

/// A value as text: numbers with the attribute's unit, yes/no, the rest as
/// it is; a file as "file".
String formatValue(Attribute? a, Object? v) => switch (v) {
  null => '',
  _ when a?.isFile ?? false => 'file',
  String s => s,
  bool b => b ? 'yes' : 'no',
  num n => withUnit(n, a?.unit),
  _ => '$v',
};

/// Values by attribute name, as items and stock rows have them.
typedef Values = Map<String, Object?>;

Values _values(Object? json) => {...?(json as Map?)?.cast<String, Object?>()};

/// A node of the class or location tree.
class TreeNode {
  TreeNode({
    required this.id,
    required this.name,
    this.code,
    this.parent,
    this.container = false,
    this.photo,
    this.stockPhotos = false,
    this.children = const [],
  });

  factory TreeNode.fromJson(Json json) => TreeNode(
    id: json['id'] as String,
    name: json['name'] as String,
    code: json['code'] as String?,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    photo: FileRef.photo('/locations/${json['id']}', json['photo']),
    stockPhotos: json['stock_photos'] as bool? ?? false,
    children: [for (final c in _list(json['children'])) TreeNode.fromJson(c)],
  );

  final String id;
  final String name;

  /// Label code; locations only.
  final String? code;
  final String? parent;

  /// Holds only other nodes: classes without items, locations without stock.
  final bool container;

  /// Locations only.
  final FileRef? photo;

  /// Locations only: whether the stock rows there may have a photo of their
  /// own (decision 116).
  final bool stockPhotos;
  final List<TreeNode> children;

  /// Set by [Tree]: the names from the root, joined by "/".
  late final String path;
  late final int depth;
}

/// The whole class or location tree, with lookups by id. Siblings come in
/// the server's natural order (A2 before A10).
class Tree {
  Tree(this.roots, {this.version, this.etag}) {
    void walk(List<TreeNode> nodes, String prefix, int depth) {
      for (final n in nodes) {
        n.path = prefix.isEmpty ? n.name : '$prefix/${n.name}';
        n.depth = depth;
        _byId[n.id] = n;
        all.add(n);
        walk(n.children, n.path, depth + 1);
      }
    }

    walk(roots, '', 0);
  }

  factory Tree.fromJson(Json json, {String? etag}) => Tree(
    [for (final n in _list(json['tree'])) TreeNode.fromJson(n)],
    version: json['version'] as int?,
    etag: etag,
  );

  final List<TreeNode> roots;
  final int? version;
  final String? etag;
  final Map<String, TreeNode> _byId = {};

  /// Every node, depth first, in tree order.
  final List<TreeNode> all = [];

  TreeNode? operator [](String? id) => id == null ? null : _byId[id];

  /// The path of a node, or its id when the tree doesn't know it.
  String pathOf(String? id) => this[id]?.path ?? id ?? '';

  /// The nodes from the root down to [id].
  List<TreeNode> ancestry(String id) {
    final out = <TreeNode>[];
    for (var n = this[id]; n != null; n = this[n.parent]) {
      out.insert(0, n);
    }
    return out;
  }

  /// [id] and every node below it.
  Set<String> subtree(String id) {
    final out = <String>{};
    void walk(TreeNode n) {
      out.add(n.id);
      n.children.forEach(walk);
    }

    final n = this[id];
    if (n != null) walk(n);
    return out;
  }
}

/// How the stock of a class's items is counted (decision 110).
enum Counting {
  /// Not counted: a stock row says it is there, and has no amount.
  none('Not counted'),

  /// Counted, and an amount may be left out: not counted yet.
  optional('Counted, the amount optional'),

  /// Counted: every stock row has an amount.
  required('Counted, the amount required');

  const Counting(this.label);

  final String label;

  static Counting fromJson(Object? v) =>
      Counting.values.asNameMap()[v] ?? Counting.optional;
}

/// A class's rule for counting its items' stock: [counting], in [unit]
/// (null: pieces), and [from], the class whose rule it is (its own id, an
/// ancestor's, or null for the default: counted, optional, in pieces).
class StockRule {
  const StockRule({this.counting = Counting.optional, this.unit, this.from});

  factory StockRule.fromJson(Object? json) {
    final j = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    return StockRule(
      counting: Counting.fromJson(j['counting']),
      unit: j['unit'] as String?,
      from: j['from'] as String?,
    );
  }

  final Counting counting;
  final String? unit;
  final String? from;

  /// "Not counted", "Counted, the amount optional · pieces", "… · m".
  String get text => counting == Counting.none
      ? counting.label
      : '${counting.label} · ${unit ?? 'pieces'}';
}

class ClassDetail {
  const ClassDetail({
    required this.id,
    required this.name,
    this.parent,
    this.container = false,
    this.path = const [],
    this.attributes = const [],
    this.stock = const StockRule(),
  });

  factory ClassDetail.fromJson(Json json) => ClassDetail(
    id: json['id'] as String,
    name: json['name'] as String,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    path: _refs(json['path']),
    attributes: _list(json['attributes']).map(Attribute.fromJson).toList(),
    stock: StockRule.fromJson(json['stock']),
  );

  final String id;
  final String name;
  final String? parent;
  final bool container;
  final List<NamedRef> path;

  /// Its own and inherited ones: the item attributes, then the stock
  /// attributes, each by order.
  final List<Attribute> attributes;

  /// How its items' stock is counted.
  final StockRule stock;

  String get pathText => path.map((p) => p.name).join('/');

  /// The attributes whose values are on the item, or on its stock rows.
  List<Attribute> scoped({required bool stock}) =>
      attributes.where((a) => a.onStock == stock).toList();

  Attribute? attribute(String name) =>
      attributes.where((a) => a.name == name).firstOrNull;
}

/// What a change of a class's attributes did, or would do in a dry run:
/// how many items and stock rows it wrote.
class ClassChange {
  const ClassChange({
    required this.cls,
    required this.items,
    required this.stock,
    required this.dryRun,
    this.relabelled = 0,
  });

  factory ClassChange.fromJson(Json json) => ClassChange(
    cls: ClassDetail.fromJson(json['class'] as Json),
    items: json['items'] as int? ?? 0,
    stock: json['stock'] as int? ?? 0,
    dryRun: json['dry_run'] as bool? ?? false,
    relabelled: json['relabelled'] as int? ?? 0,
  );

  final ClassDetail cls;
  final int items;
  final int stock;
  final bool dryRun;

  /// A change of the rule for counting stock: how many stock rows with an
  /// amount are counted in another unit (nothing converts).
  final int relabelled;

  /// "This rewrites 1,204 items and 3 stock rows.", or that it rewrites
  /// nothing.
  String get rewrites {
    if (items == 0 && stock == 0) return 'No item or stock row changes.';
    final parts = [
      if (items > 0) count(items, 'item'),
      if (stock > 0) count(stock, 'stock row'),
    ];
    return 'This rewrites ${parts.join(' and ')}.';
  }
}

/// "1 item", "1,204 items".
String count(int n, String one, [String? many]) {
  final digits = '$n'.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$digits ${n == 1 ? one : (many ?? '${one}s')}';
}

class Location {
  const Location({
    required this.id,
    required this.code,
    required this.name,
    this.parent,
    this.container = false,
    this.photo,
    this.stockPhotos = false,
    this.path = const [],
  });

  factory Location.fromJson(Json json) => Location(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    photo: FileRef.photo('/locations/${json['id']}', json['photo']),
    stockPhotos: json['stock_photos'] as bool? ?? false,
    path: _refs(json['path']),
  );

  final String id;
  final String code;
  final String name;
  final String? parent;
  final bool container;
  final FileRef? photo;

  /// Whether the stock rows there may have a photo of their own.
  final bool stockPhotos;
  final List<NamedRef> path;

  String get pathText => path.map((p) => p.name).join('/');
}

/// A file of an item, a stock row or a location: its photo ([attribute]
/// null), or the file of an attachment attribute.
class FileRef {
  const FileRef({required this.owner, this.attribute, required this.hash});

  /// /items/{id}, /stock/{id} or /locations/{id}.
  final String owner;
  final String? attribute;

  /// The SHA-256 of its content, in hex: a new file, a new hash.
  final String hash;

  /// Its route under /api/v1.
  String get path => attribute == null
      ? '$owner/photo'
      : '$owner/files/${Uri.encodeComponent(attribute!)}';

  /// "Photo", or the attribute's name, as the server names the file.
  String get title => attribute ?? 'Photo';

  static FileRef? photo(String owner, Object? hash) =>
      hash is String ? FileRef(owner: owner, hash: hash) : null;
}

class ItemSummary {
  const ItemSummary({
    required this.id,
    required this.code,
    required this.name,
    required this.classId,
    this.counting = Counting.optional,
    this.unit,
    this.photo,
  });

  factory ItemSummary.fromJson(Json json) => ItemSummary(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    classId: json['class'] is Map
        ? (json['class'] as Json)['id'] as String
        : json['class'] as String? ?? '',
    counting: Counting.fromJson(json['counting']),
    unit: json['unit'] as String?,
    photo: FileRef.photo('/items/${json['id']}', json['photo']),
  );

  final String id;
  final String code;
  final String name;
  final String classId;

  /// How its stock is counted, and in what: a label ("m"), null for
  /// pieces. Both its class's.
  final Counting counting;
  final String? unit;
  final FileRef? photo;

  /// An amount of its stock: "12", "1.5 m", "uncounted", or, where its
  /// class doesn't count its stock, "not counted".
  String amountText(num? amount) => counting == Counting.none
      ? 'not counted'
      : amount == null
      ? 'uncounted'
      : withUnit(amount, unit);
}

/// An item in a list (GET /items).
class ItemListed extends ItemSummary {
  const ItemListed({
    required super.id,
    required super.code,
    required super.name,
    required super.classId,
    super.counting,
    super.unit,
    super.photo,
    this.total = 0,
    this.uncounted = false,
  });

  factory ItemListed.fromJson(Json json) {
    final s = ItemSummary.fromJson(json);
    final stock = json['stock'] as Json? ?? const {};
    return ItemListed(
      id: s.id,
      code: s.code,
      name: s.name,
      classId: s.classId,
      counting: s.counting,
      unit: s.unit,
      photo: s.photo,
      total: stock['total'] as num? ?? 0,
      uncounted: stock['uncounted'] as bool? ?? false,
    );
  }

  /// The counted stock, and whether some is uncounted.
  final num total;
  final bool uncounted;

  /// The total stock: "12", "1.2 m", "3 + uncounted" or "uncounted"; or
  /// "not counted", or none, where its class doesn't count its stock.
  String get stockText {
    if (counting == Counting.none) return uncounted ? 'not counted' : '';
    final counted = withUnit(total, unit);
    if (!uncounted) return counted;
    return total == 0 ? 'uncounted' : '$counted + uncounted';
  }
}

class ItemDetail extends ItemSummary {
  const ItemDetail({
    required super.id,
    required super.code,
    required super.name,
    required this.cls,
    super.counting,
    super.unit,
    super.photo,
    this.values = const {},
    this.defaulted = const {},
    this.stock = const [],
  }) : super(classId: '');

  factory ItemDetail.fromJson(Json json) {
    final s = ItemSummary.fromJson(json);
    final cls = json['class'] as Json;
    return ItemDetail(
      id: s.id,
      code: s.code,
      name: s.name,
      cls: (
        id: cls['id'] as String,
        name: cls['name'] as String,
        path: _refs(cls['path']),
      ),
      counting: s.counting,
      unit: s.unit,
      photo: s.photo,
      values: _values(json['values']),
      defaulted: _strings(json['defaulted']).toSet(),
      stock: [for (final r in _list(json['stock'])) Stock.fromJson(r, item: s)],
    );
  }

  final ({String id, String name, List<NamedRef> path}) cls;

  @override
  String get classId => cls.id;

  final Values values;

  /// The names of the values that follow the class's default.
  final Set<String> defaulted;

  /// Its stock rows, by location name.
  final List<Stock> stock;

  String get classPath => cls.path.map((p) => p.name).join('/');
}

class Stock {
  const Stock({
    required this.id,
    required this.code,
    required this.item,
    required this.location,
    this.amount,
    this.photo,
    this.values = const {},
    this.defaulted = const {},
  });

  /// [item] is the item of an item's own stock rows, whose JSON has only
  /// its id.
  factory Stock.fromJson(Json json, {ItemSummary? item}) => Stock(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    item: json['item'] is Map
        ? ItemSummary.fromJson(json['item'] as Json)
        : item!,
    location: json['location'] as String,
    amount: json['amount'] as num?,
    photo: FileRef.photo('/stock/${json['id']}', json['photo']),
    values: _values(json['values']),
    defaulted: _strings(json['defaulted']).toSet(),
  );

  final String id;
  final String code;
  final ItemSummary item;
  final String location;

  /// In the item's unit; null: there, but not counted.
  final num? amount;
  final FileRef? photo;

  /// Not in list rows (GET /stock).
  final Values values;
  final Set<String> defaulted;

  String get amountText => item.amountText(amount);
}

/// One page of a list. Pages go by key: [next] is the `after` of the next
/// page, when there is [more].
class ResultPage<T> {
  const ResultPage({required this.rows, this.more = false, this.next});

  factory ResultPage.fromJson(Json json, T Function(Json) row) => ResultPage(
    rows: _list(json['rows']).map(row).toList(),
    more: json['more'] as bool? ?? false,
    next: json['next'] as String?,
  );

  final List<T> rows;
  final bool more;
  final String? next;
}

/// What a label code belongs to.
sealed class CodeTarget {
  const CodeTarget();

  factory CodeTarget.fromJson(Json json) {
    final o = json['object'] as Json;
    return switch (json['type']) {
      'location' => CodeLocation(Location.fromJson(o)),
      'item' => CodeItem(ItemDetail.fromJson(o)),
      _ => CodeStock(Stock.fromJson(o)),
    };
  }
}

class CodeLocation extends CodeTarget {
  const CodeLocation(this.location);
  final Location location;
}

class CodeItem extends CodeTarget {
  const CodeItem(this.item);
  final ItemDetail item;
}

class CodeStock extends CodeTarget {
  const CodeStock(this.stock);
  final Stock stock;
}

/// A code that was handed out, whose item, stock row or location has been
/// deleted (410).
class CodeGone extends CodeTarget {
  const CodeGone(this.code);
  final String code;
}

/// What a recursive delete would delete (or did).
class Deletion {
  const Deletion({
    required this.nodes,
    required this.uses,
    required this.useCount,
    this.stock = 0,
  });

  /// Locations: the locations, deepest first, and the stock rows at them.
  factory Deletion.locations(Json json) {
    final stock = _list(json['stock']);
    return Deletion(
      nodes: _list(json['locations']).map((l) => l['path'] as String).toList(),
      uses: stock.map((s) {
        final item = s['item'] as Json;
        return '${s['code']}  ${item['name']}';
      }).toList(),
      useCount: stock.length,
    );
  }

  /// Classes: the classes, deepest first, the items in them and their
  /// number of stock rows.
  factory Deletion.classes(Json json) {
    final items = _list(json['items']);
    return Deletion(
      nodes: _list(json['classes']).map((c) => c['path'] as String).toList(),
      uses: items.map((i) => '${i['code']}  ${i['name']}').toList(),
      useCount: items.length,
      stock: json['stock'] as int? ?? 0,
    );
  }

  final List<String> nodes;

  /// What uses them: stock rows (locations) or items (classes).
  final List<String> uses;
  final int useCount;

  /// Classes only: the stock rows of the items.
  final int stock;
}

class Account {
  const Account({
    required this.id,
    required this.email,
    required this.hasPassword,
    required this.role,
  });

  factory Account.fromJson(Json json) => Account(
    id: json['id'] as String,
    email: json['email'] as String,
    hasPassword: json['has_password'] as bool? ?? false,
    role: Role.parse(json['role']),
  );

  final String id;
  final String email;
  final bool hasPassword;
  final Role role;
}

/// The answer of POST /model/import (seed/model-format.md): how many
/// classes and attributes were (or would be) added, how many were there
/// already, and how many items and stock rows below classes that were
/// there already it wrote.
class ModelImport {
  const ModelImport({
    required this.dryRun,
    this.classesAdded = 0,
    this.classesExisting = 0,
    this.attributesAdded = 0,
    this.attributesExisting = 0,
    this.items = 0,
    this.stock = 0,
  });

  factory ModelImport.fromJson(Json json) {
    int n(String kind, String what) =>
        (json[kind] as Json?)?[what] as int? ?? 0;
    return ModelImport(
      dryRun: json['dry_run'] as bool? ?? false,
      classesAdded: n('classes', 'added'),
      classesExisting: n('classes', 'existing'),
      attributesAdded: n('attributes', 'added'),
      attributesExisting: n('attributes', 'existing'),
      items: json['items'] as int? ?? 0,
      stock: json['stock'] as int? ?? 0,
    );
  }

  final bool dryRun;
  final int classesAdded;
  final int classesExisting;
  final int attributesAdded;
  final int attributesExisting;
  final int items;
  final int stock;

  bool get nothingNew => classesAdded == 0 && attributesAdded == 0;
}
