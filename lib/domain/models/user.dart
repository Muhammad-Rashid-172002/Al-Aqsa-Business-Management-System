import 'json_utils.dart';

enum UserRole { owner, staff, technician }

enum Permission {
  viewDashboard,
  viewFinancials,
  viewPurchasePrice,
  manageProducts,
  managePurchases,
  manageSales,
  adjustStock,
  manageTechnicians,
  issueStock,
  manageCustomers,
  manageSuppliers,
  manageLedgers,
  manageQuotations,
  manageWarranty,
  manageRepairs,
  viewReports,
  backupRestore,
  manageSettings,
  manageUsers,
  allowNegativeStock,
  cancelTransactions,
  approveCredit,
  approveInspection,
  resolveSerialConflicts,
  // technician self-service
  viewOwnStock,
  submitOwnUsage,
  viewAssignedRepairs,
  manageExpenses,
}

const rolePermissions = <UserRole, Set<Permission>>{
  UserRole.owner: {...Permission.values},
  UserRole.staff: {
    Permission.viewDashboard,
    Permission.manageProducts,
    Permission.manageSales,
    Permission.manageCustomers,
    Permission.manageQuotations,
    Permission.manageWarranty,
    Permission.manageRepairs,
    Permission.issueStock,
  },
  UserRole.technician: {
    Permission.viewOwnStock,
    Permission.submitOwnUsage,
    Permission.viewAssignedRepairs,
  },
};

class AppUser {
  final String id;
  final String username;
  final String displayName;
  final String passwordHash;
  final UserRole role;
  final bool active;
  final String? employeeId;
  final bool mustChangePassword;
  final DateTime createdAt;

  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.passwordHash,
    required this.role,
    this.active = true,
    this.employeeId,
    this.mustChangePassword = false,
    required this.createdAt,
  });

  bool can(Permission p) => rolePermissions[role]!.contains(p);

  AppUser copyWith({String? displayName, String? passwordHash, bool? active, bool? mustChangePassword, UserRole? role}) =>
      AppUser(
        id: id,
        username: username,
        displayName: displayName ?? this.displayName,
        passwordHash: passwordHash ?? this.passwordHash,
        role: role ?? this.role,
        active: active ?? this.active,
        employeeId: employeeId,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'passwordHash': passwordHash,
        'role': role.name,
        'active': active,
        'employeeId': employeeId,
        'mustChangePassword': mustChangePassword,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: s(j['id']),
        username: s(j['username']),
        displayName: s(j['displayName']),
        passwordHash: s(j['passwordHash']),
        role: enumByName(UserRole.values, j['role'], UserRole.staff),
        active: b(j['active'], true),
        employeeId: sn(j['employeeId']),
        mustChangePassword: b(j['mustChangePassword']),
        createdAt: parseDate(j['createdAt']),
      );
}

class LoginEvent {
  final String id;
  final String? userId;
  final String username;
  final DateTime at;
  final bool success;
  final String note;
  const LoginEvent({required this.id, this.userId, required this.username, required this.at, required this.success, this.note = ''});

  Map<String, dynamic> toJson() =>
      {'id': id, 'userId': userId, 'username': username, 'at': at.toIso8601String(), 'success': success, 'note': note};
  factory LoginEvent.fromJson(Map<String, dynamic> j) => LoginEvent(
      id: s(j['id']), userId: sn(j['userId']), username: s(j['username']), at: parseDate(j['at']), success: b(j['success']), note: s(j['note']));
}

class Employee {
  final String id;
  final String code;
  final String name;
  final String phone;
  final String address;
  final DateTime joiningDate;
  final bool active;
  final String notes;
  final String? userId;

  const Employee({
    required this.id,
    required this.code,
    required this.name,
    this.phone = '',
    this.address = '',
    required this.joiningDate,
    this.active = true,
    this.notes = '',
    this.userId,
  });

  Employee copyWith({String? name, String? phone, String? address, bool? active, String? notes, String? userId}) => Employee(
        id: id,
        code: code,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        address: address ?? this.address,
        joiningDate: joiningDate,
        active: active ?? this.active,
        notes: notes ?? this.notes,
        userId: userId ?? this.userId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'phone': phone,
        'address': address,
        'joiningDate': joiningDate.toIso8601String(),
        'active': active,
        'notes': notes,
        'userId': userId,
      };

  factory Employee.fromJson(Map<String, dynamic> j) => Employee(
        id: s(j['id']),
        code: s(j['code']),
        name: s(j['name']),
        phone: s(j['phone']),
        address: s(j['address']),
        joiningDate: parseDate(j['joiningDate']),
        active: b(j['active'], true),
        notes: s(j['notes']),
        userId: sn(j['userId']),
      );
}

class AuditLog {
  final String id;
  final DateTime at;
  final String userId;
  final String action;
  final String entity;
  final String entityId;
  final String details;
  const AuditLog({required this.id, required this.at, required this.userId, required this.action, required this.entity, required this.entityId, this.details = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'userId': userId,
        'action': action,
        'entity': entity,
        'entityId': entityId,
        'details': details,
      };
  factory AuditLog.fromJson(Map<String, dynamic> j) => AuditLog(
        id: s(j['id']),
        at: parseDate(j['at']),
        userId: s(j['userId']),
        action: s(j['action']),
        entity: s(j['entity']),
        entityId: s(j['entityId']),
        details: s(j['details']),
      );
}
