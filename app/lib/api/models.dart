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

/// The logged-in account: GET /me, and the login answer.
class Me {
  const Me({
    required this.id,
    required this.email,
    required this.dataPrivilege,
    required this.modelPrivilege,
    required this.accountPrivilege,
    required this.historyPrivilege,
  });

  factory Me.fromJson(Json json) => Me(
    id: json['id'] as String,
    email: json['email'] as String,
    dataPrivilege: Privilege.parse(json['data_privilege']),
    modelPrivilege: Privilege.parse(json['model_privilege']),
    accountPrivilege: Privilege.parse(json['account_privilege']),
    historyPrivilege: privilegeOf(
      'history_privilege',
      json['history_privilege'],
    ),
  );

  final String id;
  final String email;
  final Privilege dataPrivilege;
  final Privilege modelPrivilege;
  final Privilege accountPrivilege;
  final Privilege historyPrivilege;
}

class NamedRef {
  const NamedRef(this.id, this.name);

  factory NamedRef.fromJson(Json json) =>
      NamedRef(json['id'] as String, json['name'] as String);

  final String id;
  final String name;
}

/// Whether a quantity or unit family can be chosen, and why: global ones
/// (every inventory has them) follow their default unless the inventory
/// chose; its own are available unless it chose not (API revision 11).
mixin Availability {
  bool get global;
  bool get available;
  bool get standard;

  /// The inventory's own choice; null follows the default.
  bool? get choice;
}

class Quantity with Availability {
  const Quantity({
    required this.id,
    required this.name,
    required this.datatype,
    this.baseSymbol = '',
    this.global = true,
    this.available = true,
    this.standard = true,
    this.choice,
  });

  factory Quantity.fromJson(Json json) => Quantity(
    id: json['id'] as String,
    name: json['name'] as String,
    datatype: json['datatype'] as String,
    baseSymbol:
        (_obj(json['base_unit']) ?? const {})['symbol'] as String? ?? '',
    global: json['global'] as bool? ?? true,
    available: json['available'] as bool? ?? true,
    standard: json['standard'] as bool? ?? true,
    choice: json['choice'] as bool?,
  );

  final String id;
  final String name;

  /// integer or float.
  final String datatype;

  /// The symbol of the unit numbers are stored in (API revision 5).
  final String baseSymbol;

  @override
  final bool global;

  /// Only from GET /quantities and /quantities/{id}; elsewhere true.
  @override
  final bool available;
  @override
  final bool standard;
  @override
  final bool? choice;
}

/// The answer of POST /model/import (seed/model-format.md): what was (or
/// would be) added, how much was there already, and the conflicts.
class ModelImport {
  const ModelImport({
    required this.applied,
    this.quantities = const [],
    this.families = const [],
    this.units = const [],
    required this.attributes,
    required this.options,
    required this.classes,
    required this.assignments,
    required this.existing,
    required this.conflicts,
  });

  factory ModelImport.fromJson(Json json) {
    List<String> added(String kind) => [
      for (final x in ((json[kind] as Json?)?['added'] as List?) ?? const [])
        '$x',
    ];
    int existing(String kind) =>
        (((json[kind] as Json?)?['existing'] as List?) ?? const []).length;
    return ModelImport(
      applied: json['applied'] as bool,
      quantities: added('quantities'),
      families: added('families'),
      units: added('units'),
      attributes: added('attributes'),
      options: added('options'),
      classes: added('classes'),
      assignments: added('assignments'),
      existing:
          existing('quantities') +
          existing('families') +
          existing('units') +
          existing('attributes') +
          existing('classes') +
          existing('assignments'),
      conflicts: [
        for (final c in _list(json['conflicts']))
          ('${c['where']}', '${c['message']}'),
      ],
    );
  }

  final bool applied;

  /// Quantity names; families as "Quantity › Family"; units as
  /// "Quantity › Family › symbol".
  final List<String> quantities;
  final List<String> families;
  final List<String> units;

  /// Attribute names; options as "Attribute: option"; classes as paths
  /// ("MCU/AVR"); assignments as "path: attribute".
  final List<String> attributes;
  final List<String> options;
  final List<String> classes;
  final List<String> assignments;

  /// How many things in the file were there already.
  final int existing;

  /// (where, message) of each conflict.
  final List<(String, String)> conflicts;

  bool get nothingNew =>
      quantities.isEmpty &&
      families.isEmpty &&
      units.isEmpty &&
      attributes.isEmpty &&
      options.isEmpty &&
      classes.isEmpty &&
      assignments.isEmpty;
}

/// base = value × baseFactor + baseOffset. Each unit is in one family of its
/// quantity, such as Metric length.
class Unit {
  const Unit({
    required this.id,
    required this.name,
    required this.symbol,
    required this.familyId,
    required this.familyName,
    required this.quantity,
    required this.baseFactor,
    required this.baseOffset,
  });

  factory Unit.fromJson(Json json) => Unit(
    id: json['id'] as String,
    name: json['name'] as String,
    symbol: json['symbol'] as String,
    familyId: (json['family'] as Json)['id'] as String,
    familyName: (json['family'] as Json)['name'] as String,
    quantity: Quantity.fromJson(json['quantity'] as Json),
    baseFactor: _exact(json['base_factor'], 1),
    baseOffset: _exact(json['base_offset'], 0),
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
  final String familyId;
  final String familyName;
  final Quantity quantity;
  final Rational baseFactor;
  final Rational baseOffset;
}

/// Units of one quantity that are used together, and that numbers are
/// scaled between on output: Metric length is nm … km.
class UnitFamily with Availability {
  const UnitFamily({
    required this.id,
    required this.name,
    required this.quantity,
    this.units = const [],
    this.global = true,
    this.available = true,
    this.standard = true,
    this.choice,
  });

  /// [quantity] when the JSON leaves it out (inside GET /quantities/{id}).
  factory UnitFamily.fromJson(Json json, {Quantity? quantity}) => UnitFamily(
    id: json['id'] as String,
    name: json['name'] as String,
    quantity: json['quantity'] == null
        ? quantity!
        : Quantity.fromJson(json['quantity'] as Json),
    units: _list(json['units']).map(Unit.fromJson).toList(),
    global: json['global'] as bool? ?? true,
    available: json['available'] as bool? ?? true,
    standard: json['standard'] as bool? ?? true,
    choice: json['choice'] as bool?,
  );

  final String id;
  final String name;
  final Quantity quantity;

  /// Smallest first.
  final List<Unit> units;

  @override
  final bool global;

  /// Whether its units can be chosen: never while its quantity is off.
  @override
  final bool available;
  @override
  final bool standard;
  @override
  final bool? choice;
}

/// A unit as shown next to a thing that has it: "mm (Metric length)", with
/// ", locked" when [lock] is set.
String unitLabel(Unit u, {bool lock = false}) =>
    '${u.symbol} (${u.familyName})${lock ? ', locked' : ''}';

/// A number written plainly: 12 rather than 12.0.
String formatNumber(num n) {
  if (n is double && n == n.truncateToDouble() && n.abs() < 1e15) {
    return n.toInt().toString();
  }
  return n.toString();
}

/// A base-unit number as shown, in the unit that scales best within the
/// family, or in the unit itself with Unit lock: "1.2 mm".
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
    this.unit,
    this.unitLock = false,
    this.options = const [],
    this.deleted = false,
  });

  factory Attribute.fromJson(Json json) => Attribute(
    id: json['id'] as String,
    name: json['name'] as String,
    datatype: json['datatype'] as String,
    unit: json['unit'] == null ? null : Unit.fromJson(json['unit'] as Json),
    unitLock: json['unit_lock'] as bool? ?? false,
    options: _list(json['options']).map(NamedRef.fromJson).toList(),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String datatype;

  /// The unit numbers are typed in; they are shown scaled within its family,
  /// or in the unit itself with [unitLock].
  final Unit? unit;
  final bool unitLock;

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

/// A file attached to items, stock rows, locations or classes.
class Attachment {
  const Attachment({
    required this.id,
    required this.owner,
    required this.title,
    required this.type,
    this.size = 0,
    this.hash = '',
    this.deleted = false,
  });

  /// [owner] is the path of the object it belongs to, such as /items/{id}.
  factory Attachment.fromJson(Json json, String owner) => Attachment(
    id: json['id'] as String,
    owner: owner,
    title: json['title'] as String,
    type: json['type'] as String? ?? '',
    size: json['size'] as int? ?? 0,
    hash: json['hash'] as String? ?? '',
    deleted: json['deleted'] as bool? ?? false,
  );

  static Attachment? maybe(Object? json, String owner) =>
      json == null ? null : Attachment.fromJson(json as Json, owner);

  final String id;

  /// The path of its object: /items/{id}, /stock/{id}, /locations/{id} or
  /// /classes/{id}. An attachment is only reached through it.
  final String owner;

  /// Its own path, under its object.
  String get path => '$owner/attachments/$id';
  final String title;

  /// The MIME type.
  final String type;

  /// In bytes.
  final int size;

  /// The SHA-256 of the content, in hex.
  final String hash;
  final bool deleted;

  String get sizeText {
    if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GiB';
    if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(1)} MiB';
    if (size >= 1 << 10) return '${(size / (1 << 10)).toStringAsFixed(1)} KiB';
    return '$size B';
  }

  /// Images the app can show itself (SVG is sent as a download).
  bool get isImage => type.startsWith('image/') && type != 'image/svg+xml';
}

List<Attachment> _attachments(Object? json, String owner) =>
    _list(json).map((a) => Attachment.fromJson(a, owner)).toList();

/// A node of the class or location tree.
class TreeNode {
  TreeNode({
    required this.id,
    required this.name,
    this.code,
    this.parent,
    this.container = false,
    this.photo,
    this.children = const [],
  });

  /// [kindPath]: /classes or /locations, the paths of its attachments.
  factory TreeNode.fromJson(Json json, String kindPath) => TreeNode(
    id: json['id'] as String,
    name: json['name'] as String,
    code: json['code'] as String?,
    parent: json['parent'] as String?,
    container: json['container'] as bool? ?? false,
    photo: Attachment.maybe(json['photo'], '$kindPath/${json['id']}'),
    children: [
      for (final c in _list(json['children'])) TreeNode.fromJson(c, kindPath),
    ],
  );

  final String id;
  final String name;

  /// Label code; locations only.
  final String? code;
  final String? parent;

  /// Holds only other nodes: classes without items, locations without stock.
  final bool container;

  /// The class or location photo.
  final Attachment? photo;
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

  factory Tree.fromJson(Json json, String kindPath, {String? etag}) => Tree(
    [for (final n in _list(json['tree'])) TreeNode.fromJson(n, kindPath)],
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
    this.photo,
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
    photo: Attachment.maybe(json['photo'], '/classes/${json['id']}'),
    attachments: _attachments(json['attachments'], '/classes/${json['id']}'),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String? parent;
  final bool container;
  final List<NamedRef> path;
  final List<ClassAttribute> attributes;

  /// One of its own image attachments, or null.
  final Attachment? photo;
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
    this.photo,
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
    photo: Attachment.maybe(json['photo'], '/locations/${json['id']}'),
    attachments: _attachments(json['attachments'], '/locations/${json['id']}'),
    deleted: json['deleted'] as bool? ?? false,
  );

  final String id;
  final String code;
  final String name;
  final String? parent;
  final bool container;
  final List<NamedRef> path;

  /// One of its own image attachments, or null.
  final Attachment? photo;
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
    this.unit,
    this.unitLock = false,
    this.deleted = false,
    this.photo,
  });

  factory ItemSummary.fromJson(Json json) => ItemSummary(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String,
    classId: json['class'] is Map
        ? (json['class'] as Json)['id'] as String
        : json['class'] as String? ?? '',
    unit: json['unit'] == null ? null : Unit.fromJson(json['unit'] as Json),
    unitLock: json['unit_lock'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
    photo: Attachment.maybe(json['photo'], '/items/${json['id']}'),
  );

  final String id;
  final String code;
  final String name;
  final String classId;

  /// The item photo.
  final Attachment? photo;

  /// The unit stock is measured in; null means pieces.
  final Unit? unit;
  final bool unitLock;
  final bool deleted;
}

/// An item in a list (GET /items).
class ItemListed extends ItemSummary {
  const ItemListed({
    required super.id,
    required super.code,
    required super.name,
    required super.classId,
    super.unit,
    super.unitLock,
    super.deleted,
    required this.stockText,
    this.incomplete = false,
    super.photo,
  });

  factory ItemListed.fromJson(Json json) {
    final s = ItemSummary.fromJson(json);
    return ItemListed(
      id: s.id,
      code: s.code,
      name: s.name,
      classId: s.classId,
      unit: s.unit,
      unitLock: s.unitLock,
      deleted: s.deleted,
      stockText: _formatTotal(_obj(json['stock'])),
      incomplete: json['incomplete'] as bool? ?? false,
      photo: s.photo,
    );
  }

  /// The total stock: "12", "1.2 m", "3 + uncounted", "uncounted" or "".
  final String stockText;

  /// The item or one of its stock rows lacks a required value.
  final bool incomplete;
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
    this.photo,
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
    photo: Attachment.maybe(json['photo'], '/stock/${json['id']}'),
    attachments: _attachments(json['attachments'], '/stock/${json['id']}'),
  );

  final String id;
  final String code;
  final String location;
  final num? quantity;
  final Display? display;
  final List<Value> values;
  final List<NamedRef> missing;
  final Attachment? photo;
  final List<Attachment> attachments;

  String get quantityText => formatQuantity(quantity, display);
}

class ItemDetail {
  const ItemDetail({
    required this.id,
    required this.code,
    required this.name,
    required this.cls,
    this.unit,
    this.unitLock = false,
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
    unit: json['unit'] == null ? null : Unit.fromJson(json['unit'] as Json),
    unitLock: json['unit_lock'] as bool? ?? false,
    values: _values(json['values']),
    missing: _refs(json['missing']),
    photo: Attachment.maybe(json['photo'], '/items/${json['id']}'),
    attachments: _attachments(json['attachments'], '/items/${json['id']}'),
    stock: _list(json['stock']).map(ItemStock.fromJson).toList(),
  );

  final String id;
  final String code;
  final String name;
  final ClassDetail cls;
  final Unit? unit;
  final bool unitLock;
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
    unit: unit,
    unitLock: unitLock,
    deleted: deleted,
    photo: photo,
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
    this.photo,
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
    photo: Attachment.maybe(json['photo'], '/stock/${json['id']}'),
    attachments: _attachments(json['attachments'], '/stock/${json['id']}'),
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

  /// One of its own image attachments, or null.
  final Attachment? photo;
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
