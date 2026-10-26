// The API's data, as Dart classes. Field names follow openapi/openapi.yaml.

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
}

class Tenant {
  const Tenant({required this.id, required this.name, required this.hostname});

  factory Tenant.fromJson(Map<String, dynamic> json) => Tenant(
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
  factory Me.fromJson(
    Map<String, dynamic> json, [
    Map<String, dynamic>? tenant,
  ]) => Me(
    id: json['id'] as String,
    email: json['email'] as String,
    dataPrivilege: Privilege.parse(json['data_privilege']),
    modelPrivilege: Privilege.parse(json['model_privilege']),
    accountPrivilege: Privilege.parse(json['account_privilege']),
    historyPrivilege: Privilege.parse(json['history_privilege']),
    tenant: Tenant.fromJson(tenant ?? json['tenant'] as Map<String, dynamic>),
  );

  final String id;
  final String email;
  final Privilege dataPrivilege;
  final Privilege modelPrivilege;
  final Privilege accountPrivilege;
  final Privilege historyPrivilege;
  final Tenant tenant;
}
