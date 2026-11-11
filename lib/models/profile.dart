enum AppRole { superAdmin, companyAdmin, supervisor, guard, client, resident }

AppRole? parseRole(String? value) {
  switch (value) {
    case 'super_admin':
      return AppRole.superAdmin;
    case 'company_admin':
      return AppRole.companyAdmin;
    case 'supervisor':
      return AppRole.supervisor;
    case 'guard':
      return AppRole.guard;
    case 'client':
      return AppRole.client;
    case 'resident':
      return AppRole.resident;
    default:
      return null;
  }
}

extension AppRoleLabel on AppRole {
  String get label {
    switch (this) {
      case AppRole.superAdmin:
        return 'Súper administrador';
      case AppRole.companyAdmin:
        return 'Administrador';
      case AppRole.supervisor:
        return 'Supervisor';
      case AppRole.guard:
        return 'Guarda';
      case AppRole.client:
        return 'Cliente';
      case AppRole.resident:
        return 'Usuario';
    }
  }
}

class Profile {
  const Profile({
    required this.id,
    required this.role,
    required this.fullName,
    required this.active,
    this.companyName,
    this.companyCode,
    this.clientName,
  });

  final String id;
  final AppRole role;
  final String fullName;
  final bool active;
  final String? companyName;
  final String? companyCode;
  final String? clientName;

  String get firstName {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    return parts.isEmpty || parts.first.isEmpty ? fullName : parts.first;
  }

  /// Devuelve null si el rol no se reconoce.
  static Profile? fromRow(Map<String, dynamic> row) {
    final role = parseRole(row['role'] as String?);
    if (role == null) return null;
    final company = row['companies'];
    final client = row['clients'];
    return Profile(
      id: row['id'] as String,
      role: role,
      fullName: (row['full_name'] as String?) ?? '',
      active: (row['active'] as bool?) ?? false,
      companyName: company is Map ? company['name'] as String? : null,
      companyCode: company is Map ? company['code'] as String? : null,
      clientName: client is Map ? client['name'] as String? : null,
    );
  }
}
