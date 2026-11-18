import 'dart:convert';
import 'dart:math';

import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/password_hasher.dart';
import '../../data/store/data_store.dart';
import '../models/user.dart';
import 'context.dart';

/// Proof that an owner (or a user holding [permission]) approved an action
/// with their password. Only [AuthService.authorize] can create one.
class Authorization {
  final String userId;
  final String userName;
  final Permission permission;
  final DateTime at;
  const Authorization._(this.userId, this.userName, this.permission, this.at);
}

class AuthService {
  final ServiceContext ctx;
  final PasswordHasher hasher;
  AuthService(this.ctx, {PasswordHasher? hasher})
    : hasher = hasher ?? const PasswordHasher();

  List<AppUser> users() =>
      ctx.all(Boxes.users, AppUser.fromJson).toList()
        ..sort((a, b) => a.username.compareTo(b.username));

  AppUser? findByUsername(String username) {
    final u = username.trim().toLowerCase();
    for (final x in users()) {
      if (x.username == u) return x;
    }
    return null;
  }

  bool get hasOwner => users().any((u) => u.role == UserRole.owner);

  /// First-run setup: creates the owner account. Only allowed once.
  Future<AppUser> createOwner({
    required String username,
    required String password,
    required String displayName,
  }) async {
    if (hasOwner) {
      throw const BusinessException('An owner account already exists.');
    }
    return _create(
      username: username,
      password: password,
      displayName: displayName,
      role: UserRole.owner,
    );
  }

  Future<AppUser> createUser({
    required String username,
    required String password,
    required String displayName,
    required UserRole role,
    String? employeeId,
    UnitOfWork? uow,
  }) async {
    ctx.require(Permission.manageUsers);
    return _create(
      username: username,
      password: password,
      displayName: displayName,
      role: role,
      employeeId: employeeId,
      uow: uow,
    );
  }

  Future<AppUser> _create({
    required String username,
    required String password,
    required String displayName,
    required UserRole role,
    String? employeeId,
    UnitOfWork? uow,
  }) async {
    final uname = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(uname)) {
      throw const ValidationException(
        'Username must be 3-30 letters, numbers, dot, dash or underscore.',
      );
    }
    validatePassword(password);
    final existing = (uow?.values(Boxes.users) ??
            ctx.store.values(Boxes.users).toList())
        .map(AppUser.fromJson);
    if (existing.any((u) => u.username == uname)) {
      throw DuplicateException('Username "$uname" is already taken.');
    }
    final user = AppUser(
      id: newId(),
      username: uname,
      displayName: displayName.trim().isEmpty ? uname : displayName.trim(),
      passwordHash: hasher.hash(password),
      role: role,
      employeeId: employeeId,
      createdAt: ctx.now(),
    );
    final w = uow ?? ctx.uow();
    w.put(Boxes.users, user.id, user.toJson());
    ctx.audit(w, 'create', 'user', user.id, '${role.name}: $uname');
    if (uow == null) await w.commit();
    return user;
  }

  static void validatePassword(String p) {
    if (p.length < 6) {
      throw const ValidationException(
        'Password must be at least 6 characters.',
      );
    }
  }

  /// Starts the app session without a sign-in screen.
  ///
  /// AL AQSA CCTV runs on a single offline shop computer, so there is no
  /// login: the session always belongs to the shop owner. An existing owner
  /// record (and everything attributed to it) is reused; on a fresh install a
  /// default "Owner" record is created with a random password that is never
  /// shown or needed. Owner-only rules (credit approval, inspection decisions,
  /// serial conflicts) are therefore satisfied by the owner session itself.
  Future<AppUser> openLocalSession() async {
    final all = users();
    final owners =
        all.where((u) => u.role == UserRole.owner).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    AppUser owner;
    final active = owners.where((u) => u.active);
    if (active.isNotEmpty) {
      owner = active.first;
    } else if (owners.isNotEmpty) {
      // Data from an older version where every owner was deactivated.
      owner = owners.first.copyWith(active: true);
      final w = ctx.uow()..put(Boxes.users, owner.id, owner.toJson());
      ctx.audit(w, 'activate', 'user', owner.id, 'local session');
      await w.commit();
    } else {
      final taken = all.map((u) => u.username).toSet();
      var uname = 'owner';
      for (var k = 2; taken.contains(uname); k++) {
        uname = 'owner$k';
      }
      final rnd = Random.secure();
      final secret = base64Url.encode(
        List<int>.generate(24, (_) => rnd.nextInt(256)),
      );
      owner = await _create(
        username: uname,
        password: secret,
        displayName: 'Owner',
        role: UserRole.owner,
      );
    }
    ctx.session.start(owner);
    return owner;
  }

  Future<AppUser> login(String username, String password) async {
    final u = findByUsername(username);
    final ok = u != null && u.active && hasher.verify(password, u.passwordHash);
    final ev = LoginEvent(
      id: newId(),
      userId: u?.id,
      username: username.trim().toLowerCase(),
      at: ctx.now(),
      success: ok,
      note:
          u == null
              ? 'unknown user'
              : (!u.active
                  ? 'account deactivated'
                  : (ok ? '' : 'wrong password')),
    );
    await ctx.store.commit([WriteOp(Boxes.loginHistory, ev.id, ev.toJson())]);
    if (u != null && !u.active) {
      throw const PermissionException(
        'This account is deactivated. Contact the owner.',
      );
    }
    if (!ok) throw const BusinessException('Incorrect username or password.');
    ctx.session.start(u);
    return u;
  }

  void logout() => ctx.session.end();

  /// Verifies another user's credentials for a one-off approval (e.g. the
  /// owner approving a credit sale on the shop counter). Does not log in.
  Future<Authorization> authorize(
    String username,
    String password,
    Permission permission,
  ) async {
    final u = findByUsername(username);
    final ok =
        u != null &&
        u.active &&
        hasher.verify(password, u.passwordHash) &&
        u.can(permission);
    final w = ctx.uow();
    ctx.audit(
      w,
      ok ? 'approval_granted' : 'approval_denied',
      'user',
      u?.id ?? username,
      permission.name,
    );
    await w.commit();
    if (!ok) {
      throw const PermissionException(
        'Approval failed: wrong password or this user cannot approve it.',
      );
    }
    return Authorization._(u.id, u.displayName, permission, ctx.now());
  }

  /// Current user's own authorization if they already hold [permission].
  Authorization? selfAuthorization(Permission permission) {
    final u = ctx.session.user;
    if (u == null || !u.can(permission)) return null;
    return Authorization._(u.id, u.displayName, permission, ctx.now());
  }

  Future<void> setActive(String userId, bool active) async {
    ctx.require(Permission.manageUsers);
    if (userId == ctx.session.user?.id && !active) {
      throw const BusinessException('You cannot deactivate your own account.');
    }
    final j = ctx.store.read(Boxes.users, userId);
    if (j == null) throw const NotFoundException('User not found.');
    final u = AppUser.fromJson(j);
    if (u.role == UserRole.owner && !active) {
      final owners =
          users().where((x) => x.role == UserRole.owner && x.active).length;
      if (owners <= 1) {
        throw const BusinessException(
          'At least one active owner account is required.',
        );
      }
    }
    final w =
        ctx.uow()..put(Boxes.users, u.id, u.copyWith(active: active).toJson());
    ctx.audit(w, active ? 'activate' : 'deactivate', 'user', u.id);
    await w.commit();
  }

  List<LoginEvent> loginHistory({int limit = 200}) {
    final all =
        ctx.all(Boxes.loginHistory, LoginEvent.fromJson).toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return all.take(limit).toList();
  }
}
