import 'dart:async';

import 'package:melai_nuts/core/services/staff_session_store.dart';
import 'package:melai_nuts/data/models/staff_context.dart';
import 'package:melai_nuts/data/repositories/staff_profile_repository.dart';

/// A `get_my_staff_context()` payload, shaped exactly like the server's.
/// Built from parameters — it is test INPUT for the parser, never app data.
Map<String, dynamic> staffPayload({
  String uid = 'staff-a',
  String role = 'staff',
  String? branchId = 'branch-a',
  String branchName = 'Branch A',
  List<String>? permissions,
  List<Map<String, String>>? branches,
  String accountStatus = 'active',
  bool inventory = true,
  bool refunds = false,
}) {
  return {
    'status': 'active',
    'profile': {
      'firebase_uid': uid,
      'full_name': 'Test $uid',
      'email': '$uid@test.local',
      'phone': null,
      'profile_image': null,
      'role': role,
      'branch_id': branchId,
      'branch_name': branchId == null ? null : branchName,
      'account_status': accountStatus,
      'is_active': accountStatus == 'active',
      'can_manage_inventory': inventory,
      'can_review_refunds': refunds,
      'created_at': '2026-09-30T00:00:00Z',
    },
    'permissions': permissions ??
        [
          'view_dashboard',
          'view_inventory',
          if (inventory) 'manage_inventory',
          if (refunds) 'manage_refunds',
        ],
    'authorized_branches': branches ??
        [
          if (branchId != null) {'id': branchId, 'name': branchName},
        ],
  };
}

/// An `active` result. Pass [loadedAt] to stamp it with a test's fake clock.
StaffContextResult activeResult(String uid, {Map<String, dynamic>? payload, DateTime? loadedAt}) {
  final data = payload ?? staffPayload(uid: uid);
  if (loadedAt == null) return StaffProfileRepository.parseContext(data, expectedUid: uid);
  return StaffContextResult(StaffContextStatus.active, StaffContext.fromJson(data, loadedAt: loadedAt));
}

StaffContext contextFor(String uid, {Map<String, dynamic>? payload, DateTime? loadedAt}) =>
    StaffContext.fromJson(payload ?? staffPayload(uid: uid), loadedAt: loadedAt);

/// Stand-in for Firebase: who is signed in, and a stream of changes.
class FakeStaffAuth implements StaffAuthSource {
  FakeStaffAuth([this.uid]);

  String? uid;
  final StreamController<String?> _changes = StreamController<String?>.broadcast(sync: true);

  @override
  String? get currentUid => uid;

  @override
  Stream<String?> get uidChanges => _changes.stream;

  void signIn(String? next) {
    uid = next;
    _changes.add(next);
  }

  void signOut() => signIn(null);
}
