/// The Supabase-side identity of a signed-in staff member or owner: who they
/// are, which branch(es) they may work in, and what they are allowed to do.
///
/// This is the answer to `get_my_staff_context()` (see
/// supabase/migrations/20260930010000_staff_foundation.sql), keyed by the
/// Firebase UID and backed by the single `staff_members` registry:
///
///   Firebase UID  ->  staff_members row  ->  branches  +  permissions
///
/// SECURITY: everything here is a UX convenience (hide a button, pick a
/// default branch filter). The database re-checks the same rules on every
/// request (`_require_staff`, `staff_has_permission()`, RLS), so editing this
/// object on a modified device grants nothing.
library;

import 'staff_models.dart';

/// The staff roles the app knows. These are the roles that already exist in
/// the project (`staff`, `owner`); the registry's CHECK constraint allows no
/// others. An owner is a superset of staff.
enum StaffRole {
  staff,
  owner;

  /// Parses the server's role string, or throws [InvalidStaffRoleException]
  /// rather than defaulting to some role.
  static StaffRole parse(Object? value) {
    for (final role in StaffRole.values) {
      if (role.name == value) return role;
    }
    throw const InvalidStaffRoleException();
  }
}

/// The server answered with a role this app does not know.
class InvalidStaffRoleException extends FormatException {
  const InvalidStaffRoleException() : super('Staff role is unknown.');
}

/// A staff member's registry row has no usable branch.
class InvalidStaffBranchException extends FormatException {
  const InvalidStaffBranchException() : super('Staff profile has no branch.');
}

/// Permission keys. They mirror `staff_permission_catalog()` in the database;
/// the server decides which of them a caller holds and sends that list, so the
/// app never derives permissions on its own. Later batches check these keys
/// (UI and route gating) while the database enforces the same rules.
class StaffPermission {
  StaffPermission._();

  static const String viewDashboard = 'view_dashboard';
  static const String viewProducts = 'view_products';
  static const String manageProducts = 'manage_products';
  static const String viewInventory = 'view_inventory';
  static const String manageInventory = 'manage_inventory';
  static const String viewOrders = 'view_orders';
  static const String manageOrders = 'manage_orders';
  static const String viewPayments = 'view_payments';
  static const String manageRefunds = 'manage_refunds';
  static const String viewReports = 'view_reports';
  static const String manageStockTransfers = 'manage_stock_transfers';
  static const String viewNotifications = 'view_notifications';

  /// Earlier names kept so existing callers keep compiling.
  static const String inventoryManage = manageInventory;
  static const String refundsReview = manageRefunds;

  static const Set<String> catalog = <String>{
    viewDashboard,
    viewProducts,
    manageProducts,
    viewInventory,
    manageInventory,
    viewOrders,
    manageOrders,
    viewPayments,
    manageRefunds,
    viewReports,
    manageStockTransfers,
    viewNotifications,
  };
}

/// A branch the signed-in account may access (id + display name).
class StaffBranchRef {
  final String id;
  final String name;

  const StaffBranchRef({required this.id, required this.name});

  factory StaffBranchRef.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) {
      throw const FormatException('Branch reference is incomplete.');
    }
    return StaffBranchRef(id: id, name: name);
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is StaffBranchRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Profile + permissions + branch access for one staff member or owner,
/// loaded in a single atomic server read so they can never disagree.
class StaffContext {
  /// The Firebase UID this context belongs to.
  final String firebaseUid;
  final StaffProfile profile;

  /// Unmodifiable set of granted permission keys (see [StaffPermission]).
  final Set<String> permissions;

  /// Unmodifiable list of branches the server says this account may access.
  /// Staff: their assigned branch. Owner: every branch.
  final List<StaffBranchRef> authorizedBranches;

  /// When this context was fetched from the server.
  final DateTime loadedAt;

  StaffContext({
    required this.firebaseUid,
    required this.profile,
    required Set<String> permissions,
    List<StaffBranchRef> authorizedBranches = const <StaffBranchRef>[],
    DateTime? loadedAt,
  })  : permissions = Set<String>.unmodifiable(permissions),
        authorizedBranches = List<StaffBranchRef>.unmodifiable(authorizedBranches),
        loadedAt = loadedAt ?? DateTime.now();

  StaffRole get role => StaffRole.parse(profile.role);
  bool get isOwner => profile.isOwner;
  String? get branchId => profile.branchId;
  String? get branchName => profile.branchName;
  String get fullName => profile.fullName;

  bool can(String permission) => permissions.contains(permission);

  bool canAny(Iterable<String> candidates) => candidates.any(permissions.contains);

  bool canAll(Iterable<String> required) => required.every(permissions.contains);

  /// True when the server listed [branchId] as accessible to this account.
  bool canAccessBranch(String branchId) =>
      authorizedBranches.any((b) => b.id == branchId);

  /// Parses the `active` payload of `get_my_staff_context()` (and the cached
  /// copy of it). Throws rather than guessing — a partial profile must never
  /// be treated as a valid one:
  ///  * [InvalidStaffRoleException]   unknown role
  ///  * [InvalidStaffBranchException] staff without a branch
  ///  * [FormatException]             anything else malformed
  factory StaffContext.fromJson(Map<String, dynamic> json, {DateTime? loadedAt}) {
    final raw = json['profile'];
    if (raw is! Map) throw const FormatException('Staff context is incomplete.');
    final p = Map<String, dynamic>.from(raw);
    final uid = p['firebase_uid'];
    if (uid is! String || uid.isEmpty || p['full_name'] is! String) {
      throw const FormatException('Staff profile is incomplete.');
    }
    final role = StaffRole.parse(p['role']);
    final branchId = p['branch_id'];
    // Staff must be tied to a branch; only owners may have none.
    if (role == StaffRole.staff && (branchId is! String || branchId.isEmpty)) {
      throw const InvalidStaffBranchException();
    }

    final rawPermissions = json['permissions'];
    if (rawPermissions is! List) {
      throw const FormatException('Staff permissions are missing.');
    }
    // Unknown keys (a newer server) are ignored, never trusted.
    final permissions = <String>{
      for (final k in rawPermissions)
        if (k is String && StaffPermission.catalog.contains(k)) k,
    };

    final rawBranches = json['authorized_branches'];
    if (rawBranches is! List) {
      throw const FormatException('Staff branch access is missing.');
    }
    final branches = <StaffBranchRef>[
      for (final b in rawBranches)
        StaffBranchRef.fromJson(Map<String, dynamic>.from(b as Map)),
    ];
    if (role == StaffRole.staff && !branches.any((b) => b.id == branchId)) {
      // The assigned branch must be one the server authorizes.
      throw const InvalidStaffBranchException();
    }

    return StaffContext(
      firebaseUid: uid,
      profile: StaffProfile.fromJson(p),
      permissions: permissions,
      authorizedBranches: branches,
      loadedAt: loadedAt,
    );
  }

  /// Same shape [StaffContext.fromJson] reads (used for the offline cache).
  Map<String, dynamic> toJson() => {
        'status': 'active',
        'profile': profile.toJson(),
        'permissions': (permissions.toList()..sort()),
        'authorized_branches': [for (final b in authorizedBranches) b.toJson()],
      };
}
