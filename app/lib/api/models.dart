// The API's data, as Dart classes. Field names follow openapi/openapi.yaml.

import 'units.dart';

typedef Json = Map<String, dynamic>;

Json? _obj(Object? o) => o as Json?;
List<Json> _list(Object? o) => (o as List?)?.cast<Json>() ?? const [];

enum Privilege {
  none('none'),
  readOnly('read_only'),
  readWrite('read_write');

  const Privilege(this.json);

  final String json;

  static Privilege parse(Object? value) =>
      values.firstWhere((p) => p.json == value, orElse: () => none);

  String get label => switch (this) {
    none => 'None',
    readOnly => 'Read only',
    readWrite => 'Read and write',
  };

  bool get canRead => this != none;
  bool get canWrite => this == readWrite;
}

class Tenant {
  const Tenant({required this.id, required this.name, required this.hostname});

  factory Tenant.fromJson(Json json) => Tenant(
    id: json['id'] as String,
    name: json['name'] as String,
    hostname: json['hostname'] as String,
  );

  final String id;
  final String name;
  final String hostname;
}

/// The logged-in account and its tenant: GET /me, and the login answer.
class Me {
  const Me({
    required this.id,
    required this.email,
    required this.dataPrivilege,
    required this.modelPrivilege,
    required this.accountPrivilege,
    required this.historyPrivilege,
    required this.tenant,
  });

  /// [json] is an account; the tenant is in [tenant], or in json['tenant'].
  factory Me.fromJson(Json json, [Json? tenant]) => Me(
    id: json['id'] as String,
    email: json['email'] as String,
    dataPrivilege: Privilege.parse(json['data_privilege']),
    modelPrivilege: Privilege.parse(json['model_privilege']),
    accountPrivilege: Privilege.parse(json['account_privilege']),
    historyPrivilege: privilegeOf(
      'history_privilege',
      json['history_privilege'],
    ),
    tenant: Tenant.fromJson(tenant ?? json['tenant'] as Json),
  );

  final String id;
  final String email;
  final Privilege dataPrivilege;
  final Privilege modelPrivilege;
  final Privilege accountPrivilege;
  final Privilege historyPrivilege;
  final Tenant tenant;
}

class NamedRef {
  const NamedRef(this.id, this.name);

  factory NamedRef.fromJson(Json json) =>
      NamedRef(json['id'] as String, json['name'] as String);

  final String id;
  final String name;
}

class Quantity {
  const Quantity({
    required this.id,
    required this.name,
    required this.datatype,
  });

  factory Quantity.fromJson(Json json) => Quantity(
    id: json['id'] as String,
    name: json['name'] as String,
    datatype: json['datatype'] as String,
  );

  final String id;
  final String name;

  /// integer or float.
  final String datatype;
}

/// base = value × baseFactor + baseOffset.
class Unit {
  const Unit({
    required this.id,
    required this.name,
    required this.symbol,
    required this.baseFactor,
    required this.baseOffset,
    required this.isBase,
  });

  factory Unit.fromJson(Json json) => Unit(
    id: json['id'] as String,
    name: json['name'] as String,
    symbol: json['symbol'] as String,
    baseFactor: _exact(json['base_factor'], 1),
    baseOffset: _exact(json['base_offset'], 0),
    isBase: json['is_base'] as bool? ?? false,
  );

  /// The client passes factors as text, exactly as the server wrote them
  /// (see decodeBody); a number is taken by its shortest decimal form.
  static Rational _exact(Object? v, int fallback) => switch (v) {
    String s =>
      Rational.tryParse(s) ?? (throw FormatException('not a number: $s')),
    num n => Rational.fromNum(n),
    _ => Rational(BigInt.from(fallback)),
  };

  final String id;
  final String name;
  final String symbol;
  final Rational baseFactor;
  final Rational baseOffset;
  final bool isBase;
}

class UnitGroup {
  const UnitGroup({
    required this.id,
    required this.name,
    required this.quantity,
    this.units = const [],
  });

  factory UnitGroup.fromJson(Json json) => UnitGroup(
    id: json['id'] as String,
    name: json['name'] as String,
    quantity: Quantity.fromJson(json['quantity'] as Json),
    units: _list(json['units']).map(Unit.fromJson).toList(),
  );

  final String id;
  final String name;
  final Quantity quantity;

  /// Smallest first; only in GET /unit-groups/{id}.
  final List<Unit> units;
}

/// A number written plainly: 12 rather than 12.0.
String formatNumber(num n) {
  if (n is double && n == n.truncateToDouble() && n.abs() < 1e15) {
    return n.toInt().toString();
  }
  return n.toString();
}

/// A base-unit number in the best-scaling unit of its group: "1.2 mm".
class Display {
  const Display(this.value, this.symbol);

  static Display? fromJson(Object? json) {
    final j = _obj(json);
    if (j == null) return null;
    return Display(j['value'] as num, (j['unit'] as Json)['symbol'] as String);
  }

  final num value;
  final String symbol;

  @override
  String toString() => '${formatNumber(value)} $symbol';
}

/// A stock quantity: in its display unit, a plain count, or "uncounted".
String formatQuantity(num? quantity, Display? display) {
  if (quantity == null) return 'uncounted';
  return display?.toString() ?? formatNumber(quantity);
}

const datatypes = [
  'text',
  'integer',
  'float',
  'date',
  'boolean',
  'url',
  'choice',
];

class Attribute {
  const Attribute({
    required this.id,
    required this.name,
    required this.datatype,
    this.unitGroup,
    this.options = const [],
    this.deleted = false,
  });

  factory Attribute.fromJson(Json json) => Attribute(
    id: json['id'] as String,
    name: json['name'] as String,
    datatype: json['datatype'] as String,
    unitGroup: json['unit_group'] == null
        ? null
        : UnitGroup.fromJson(json['unit_group'] as Json),
    options: _list(json['options']).map(NamedRef.fromJson).toList(),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String datatype;
  final UnitGroup? unitGroup;

  /// Only for choice attributes, in GET /attributes/{id}.
  final List<NamedRef> options;
  final bool deleted;

  bool get isNumber => datatype == 'integer' || datatype == 'float';
}

/// A typed value as text: strings as they are, booleans as yes/no, choices
/// by name, numbers plainly.
String formatJsonValue(Object? v) => switch (v) {
  null => '',
  String s => s,
  bool b => b ? 'yes' : 'no',
  num n => formatNumber(n),
  Map m when m['name'] is String => m['name'] as String,
  _ => '$v',
};

class Value {
  const Value({
    required this.attribute,
    required this.value,
    this.display,
    this.isDefault = false,
  });

  factory Value.fromJson(Json json) => Value(
    attribute: Attribute.fromJson(json['attribute'] as Json),
    value: json['value'],
    display: Display.fromJson(json['display']),
    isDefault: json['is_default'] as bool? ?? false,
  );

  final Attribute attribute;
  final Object? value;
  final Display? display;

  /// The class default, shown because there is no own value.
  final bool isDefault;

  /// In the display unit when it has one.
  String get text => display?.toString() ?? formatJsonValue(value);
}

List<Value> _values(Object? json) => _list(json).map(Value.fromJson).toList();
List<NamedRef> _refs(Object? json) =>
    _list(json).map(NamedRef.fromJson).toList();

class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.size,
    this.caption,
    this.primaryPhoto = false,
    this.deleted = false,
  });

  factory Attachment.fromJson(Json json) => Attachment(
    id: json['id'] as String,
    fileName: json['file_name'] as String,
    contentType: json['content_type'] as String? ?? '',
    size: json['size'] as int? ?? 0,
    caption: json['caption'] as String?,
    primaryPhoto: json['primary_photo'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
  );

  static Attachment? maybe(Object? json) =>
      json == null ? null : Attachment.fromJson(json as Json);

  final String id;
  final String fileName;
  final String contentType;
  final int size;
  final String? caption;
  final bool primaryPhoto;
  final bool deleted;

  /// Images the app can show itself (SVG is sent as a download).
  bool get isImage =>
      contentType.startsWith('image/') && contentType != 'image/svg+xml';

  String get sizeText {
    if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GiB';
    if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(1)} MiB';
    if (size >= 1 << 10) return '${(size / (1 << 10)).toStringAsFixed(1)} KiB';
    return '$size B';
  }
}

List<Attachment> _attachments(Object? json) =>
    _list(json).map(Attachment.fromJson).toList();

/// A node of the class or location tree.
class TreeNode {
  TreeNode({
    required this.id,
    required this.name,
    this.code,
    this.parent,
    this.container = false,
    this.children = const [],
  });

  factory TreeNode.fromJson(Json json) => TreeNode(
    id: json['id'] as String,
    name: json['name'] as String,
    code: json['code'] as String?,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    children: _list(json['children']).map(TreeNode.fromJson).toList(),
  );

  final String id;
  final String name;

  /// Label code; locations only.
  final String? code;
  final String? parent;

  /// Holds only other nodes: classes without items, locations without stock.
  final bool container;
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
    _list(json['tree']).map(TreeNode.fromJson).toList(),
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

class ClassAttribute {
  const ClassAttribute({
    required this.attribute,
    required this.definedOnClass,
    required this.inherited,
    required this.defaultValue,
    this.defaultDisplay,
    required this.perUnit,
    required this.required,
  });

  factory ClassAttribute.fromJson(Json json) => ClassAttribute(
    attribute: Attribute.fromJson(json['attribute'] as Json),
    definedOnClass: json['defined_on_class'] as String? ?? '',
    inherited: json['inherited'] as bool? ?? false,
    defaultValue: json['default'],
    defaultDisplay: Display.fromJson(json['default_display']),
    perUnit: json['per_unit'] as bool? ?? false,
    required: json['required'] as bool? ?? false,
  );

  final Attribute attribute;
  final String definedOnClass;
  final bool inherited;
  final Object? defaultValue;
  final Display? defaultDisplay;

  /// Values live on stock rows instead of on the item.
  final bool perUnit;
  final bool required;

  String get defaultText => defaultValue == null
      ? ''
      : defaultDisplay?.toString() ?? formatJsonValue(defaultValue);
}

class ClassDetail {
  const ClassDetail({
    required this.id,
    required this.name,
    this.parent,
    this.container = false,
    this.path = const [],
    this.attributes = const [],
    this.attachments = const [],
    this.deleted = false,
  });

  factory ClassDetail.fromJson(Json json) => ClassDetail(
    id: json['id'] as String,
    name: json['name'] as String,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    path: _refs(json['path']),
    attributes: _list(json['attributes']).map(ClassAttribute.fromJson).toList(),
    attachments: _attachments(json['attachments']),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String? parent;
  final bool container;
  final List<NamedRef> path;
  final List<ClassAttribute> attributes;
  final List<Attachment> attachments;
  final bool deleted;

  String get pathText => path.map((p) => p.name).join('/');
}

class Location {
  const Location({
    required this.id,
    required this.code,
    required this.name,
    this.parent,
    this.container = false,
    this.path = const [],
    this.attachments = const [],
    this.deleted = false,
  });

  factory Location.fromJson(Json json) => Location(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    path: _refs(json['path']),
    attachments: _attachments(json['attachments']),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String code;
  final String name;
  final String? parent;
  final bool container;
  final List<NamedRef> path;
  final List<Attachment> attachments;
  final bool deleted;

  String get pathText => path.map((p) => p.name).join('/');
}

class ItemSummary {
  const ItemSummary({
    required this.id,
    required this.code,
    required this.name,
    required this.classId,
    this.unitGroup,
    this.deleted = false,
  });

  factory ItemSummary.fromJson(Json json) => ItemSummary(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    classId: json['class'] is Map
        ? (json['class'] as Json)['id'] as String
        : json['class'] as String? ?? '',
    unitGroup: json['unit_group'] == null
        ? null
        : UnitGroup.fromJson(json['unit_group'] as Json),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String code;
  final String name;
  final String classId;

  /// The unit group stock is measured in; null means pieces.
  final UnitGroup? unitGroup;
  final bool deleted;
}

/// An item in a list (GET /items).
class ItemListed extends ItemSummary {
  const ItemListed({
    required super.id,
    required super.code,
    required super.name,
    required super.classId,
    super.unitGroup,
    super.deleted,
    required this.stockText,
    this.incomplete = false,
    this.photo,
  });

  factory ItemListed.fromJson(Json json) {
    final s = ItemSummary.fromJson(json);
    return ItemListed(
      id: s.id,
      code: s.code,
      name: s.name,
      classId: s.classId,
      unitGroup: s.unitGroup,
      deleted: s.deleted,
      stockText: _formatTotal(_obj(json['stock'])),
      incomplete: json['incomplete'] as bool? ?? false,
      photo: Attachment.maybe(json['photo']),
    );
  }

  /// The total stock: "12", "1.2 m", "3 + uncounted", "uncounted" or "".
  final String stockText;

  /// The item or one of its stock rows lacks a required value.
  final bool incomplete;
  final Attachment? photo;
}

String _formatTotal(Json? t) {
  if (t == null) return '';
  var s = formatNumber(t['total'] as num? ?? 0);
  final d = Display.fromJson(t['display']);
  if (d != null) s = d.toString();
  if (t['uncounted'] == true) return s == '0' ? 'uncounted' : '$s + uncounted';
  return s;
}

/// A stock row of an item, as GET /items/{id} lists them.
class ItemStock {
  const ItemStock({
    required this.id,
    required this.code,
    required this.location,
    this.quantity,
    this.display,
    this.values = const [],
    this.missing = const [],
    this.attachments = const [],
  });

  factory ItemStock.fromJson(Json json) => ItemStock(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    location: json['location'] as String,
    quantity: json['quantity'] as num?,
    display: Display.fromJson(json['display']),
    values: _values(json['values']),
    missing: _refs(json['missing']),
    attachments: _attachments(json['attachments']),
  );

  final String id;
  final String code;
  final String location;
  final num? quantity;
  final Display? display;
  final List<Value> values;
  final List<NamedRef> missing;
  final List<Attachment> attachments;

  String get quantityText => formatQuantity(quantity, display);
}

class ItemDetail {
  const ItemDetail({
    required this.id,
    required this.code,
    required this.name,
    required this.cls,
    this.unitGroup,
    this.values = const [],
    this.missing = const [],
    this.photo,
    this.attachments = const [],
    this.stock = const [],
    this.deleted = false,
  });

  factory ItemDetail.fromJson(Json json) => ItemDetail(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    deleted: json['deleted'] as bool? ?? false,
    cls: ClassDetail.fromJson(json['class'] as Json),
    unitGroup: json['unit_group'] == null
        ? null
        : UnitGroup.fromJson(json['unit_group'] as Json),
    values: _values(json['values']),
    missing: _refs(json['missing']),
    photo: Attachment.maybe(json['photo']),
    attachments: _attachments(json['attachments']),
    stock: _list(json['stock']).map(ItemStock.fromJson).toList(),
  );

  final String id;
  final String code;
  final String name;
  final ClassDetail cls;
  final UnitGroup? unitGroup;
  final List<Value> values;
  final List<NamedRef> missing;
  final Attachment? photo;
  final List<Attachment> attachments;

  /// The live stock rows; for a deleted item, those deleted with it.
  final List<ItemStock> stock;
  final bool deleted;

  ItemSummary get summary => ItemSummary(
    id: id,
    code: code,
    name: name,
    classId: cls.id,
    unitGroup: unitGroup,
    deleted: deleted,
  );
}

class Stock {
  const Stock({
    required this.id,
    required this.code,
    required this.item,
    required this.location,
    this.quantity,
    this.display,
    this.values = const [],
    this.missing = const [],
    this.attachments = const [],
    this.deleted = false,
    this.mergedInto,
  });

  factory Stock.fromJson(Json json) => Stock(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    item: ItemSummary.fromJson(json['item'] as Json),
    location: json['location'] as String,
    quantity: json['quantity'] as num?,
    display: Display.fromJson(json['display']),
    values: _values(json['values']),
    missing: _refs(json['missing']),
    attachments: _attachments(json['attachments']),
    deleted: json['deleted'] as bool? ?? false,
    mergedInto: _obj(json['merged_into'])?['code'] as String?,
  );

  final bool deleted;

  /// For a row a move merged into another: that row's code.
  final String? mergedInto;

  final String id;
  final String code;
  final ItemSummary item;
  final String location;
  final num? quantity;
  final Display? display;

  /// Not in list rows (GET /stock).
  final List<Value> values;
  final List<NamedRef> missing;
  final List<Attachment> attachments;

  String get quantityText => formatQuantity(quantity, display);
}

/// One page of a list.
class ResultPage<T> {
  const ResultPage({
    required this.total,
    required this.offset,
    required this.rows,
  });

  factory ResultPage.fromJson(Json json, T Function(Json) row) => ResultPage(
    total: json['total'] as int? ?? 0,
    offset: json['offset'] as int? ?? 0,
    rows: _list(json['rows']).map(row).toList(),
  );

  final int total;
  final int offset;
  final List<T> rows;
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

/// The privileges of an account, by their API names.
const privilegeKeys = {
  'data_privilege': 'Items and stock',
  'model_privilege': 'Classes, locations and attributes',
  'account_privilege': 'Accounts',
  'history_privilege': 'History',
};

/// Privileges that can only be read: history is written by the database's
/// triggers alone, and its read_write counts as read_only.
const readOnlyPrivileges = {'history_privilege'};

/// [value] as it applies to the privilege [key].
Privilege privilegeOf(String key, Object? value) {
  final p = Privilege.parse(value);
  return readOnlyPrivileges.contains(key) && p == Privilege.readWrite
      ? Privilege.readOnly
      : p;
}

class Account {
  const Account({
    required this.id,
    required this.email,
    required this.hasPassword,
    required this.privileges,
    this.deleted = false,
  });

  factory Account.fromJson(Json json) => Account(
    id: json['id'] as String,
    email: json['email'] as String,
    hasPassword: json['has_password'] as bool? ?? false,
    privileges: {
      for (final k in privilegeKeys.keys) k: privilegeOf(k, json[k]),
    },
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String email;
  final bool hasPassword;

  /// By their API names (data_privilege, …).
  final Map<String, Privilege> privileges;

  /// Deleted accounts can't log in; they stay because history refers to them.
  final bool deleted;
}

/// One history entry: one changed row (see api/history.md), as the server
/// sends it. The history screen turns entries into sentences
/// (history_text.dart).
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    this.happenedAt,
    required this.transaction,
    this.who,
    this.whoDeleted = false,
    required this.table,
    required this.operation,
    this.data = const {},
    this.changes = const {},
  });

  factory HistoryEntry.fromJson(Json json) {
    final account = _obj(json['account']);
    return HistoryEntry(
      id: json['id'] as int? ?? 0,
      happenedAt: DateTime.tryParse(json['happened_at'] as String? ?? '')
          ?.toLocal(),
      transaction: json['transaction']?.toString() ?? '',
      who: account?['email'] as String?,
      whoDeleted: account?['deleted'] == true,
      table: json['table'] as String? ?? '',
      operation: json['operation'] as String? ?? '',
      data: _obj(json['data']) ?? const {},
      changes: _obj(json['changes']) ?? const {},
    );
  }

  final int id;

  /// The start of the transaction: the same for everything one action did.
  final DateTime? happenedAt;
  final String transaction;

  /// The account's email; null for changes outside the API.
  final String? who;
  final bool whoDeleted;

  /// item, value, stock, stock_value, location, class, class_attribute,
  /// attribute, attribute_option, attachment or account.
  final String table;

  /// insert, update or delete.
  final String operation;

  /// The row after the change (before it, for a delete).
  final Json data;

  /// Updates only: {column: {old, new}}.
  final Json changes;

  /// The row's id.
  String get rowId => data['id']?.toString() ?? '';

  /// The old and new value of a changed column, or null.
  ({Object? old, Object? now})? change(String column) {
    final c = changes[column];
    if (c is! Map) return null;
    return (old: c['old'], now: c['new']);
  }

  /// Marking the row deleted (since migration 0010, a delete is an update).
  bool get marksDeleted => change('deleted')?.now == true;

  /// Restoring it.
  bool get marksRestored => change('deleted')?.now == false;
}
