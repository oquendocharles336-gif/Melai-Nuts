import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/config/supabase_config.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/staff_context.dart';
import 'package:melai_nuts/data/repositories/staff_profile_repository.dart';

import 'support/staff_fixtures.dart';

String _jwtWithRole(String role) {
  String seg(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg({'role': role})}.signature';
}

void main() {
  group('StaffContext.fromJson', () {
    test('parses profile, branch, permissions and authorized branches', () {
      final ctx = StaffContext.fromJson(staffPayload());
      expect(ctx.firebaseUid, 'staff-a');
      expect(ctx.fullName, 'Test staff-a');
      expect(ctx.role, StaffRole.staff);
      expect(ctx.branchId, 'branch-a');
      expect(ctx.branchName, 'Branch A');
      expect(ctx.isOwner, isFalse);
      expect(ctx.profile.accountStatus, 'active');
      expect(ctx.can(StaffPermission.manageInventory), isTrue);
      expect(ctx.can(StaffPermission.manageRefunds), isFalse);
      expect(ctx.canAny([StaffPermission.manageRefunds, StaffPermission.manageInventory]), isTrue);
      expect(ctx.canAll([StaffPermission.manageRefunds, StaffPermission.manageInventory]), isFalse);
      expect(ctx.authorizedBranches, [const StaffBranchRef(id: 'branch-a', name: 'Branch A')]);
      expect(ctx.canAccessBranch('branch-a'), isTrue);
      expect(ctx.canAccessBranch('branch-b'), isFalse);
    });

    test('the legacy permission names point at the new catalog keys', () {
      expect(StaffPermission.inventoryManage, StaffPermission.manageInventory);
      expect(StaffPermission.refundsReview, StaffPermission.manageRefunds);
    });

    test('unknown permission keys from a newer server are ignored, not trusted', () {
      final ctx = StaffContext.fromJson(
        staffPayload(permissions: ['view_dashboard', 'delete_everything']),
      );
      expect(ctx.permissions, {'view_dashboard'});
    });

    test('permissions and branches cannot be mutated after loading', () {
      final ctx = StaffContext.fromJson(staffPayload());
      expect(() => ctx.permissions.add(StaffPermission.manageRefunds), throwsUnsupportedError);
      expect(
        () => ctx.authorizedBranches.add(const StaffBranchRef(id: 'x', name: 'X')),
        throwsUnsupportedError,
      );
      expect(ctx.can(StaffPermission.manageRefunds), isFalse);
    });

    test('an owner needs no branch and sees every authorized branch', () {
      final ctx = StaffContext.fromJson(staffPayload(
        uid: 'owner-1',
        role: 'owner',
        branchId: null,
        branches: [
          {'id': 'b1', 'name': 'One'},
          {'id': 'b2', 'name': 'Two'},
        ],
        permissions: StaffPermission.catalog.toList(),
      ));
      expect(ctx.role, StaffRole.owner);
      expect(ctx.isOwner, isTrue);
      expect(ctx.branchId, isNull);
      expect(ctx.canAccessBranch('b2'), isTrue);
      expect(ctx.permissions, StaffPermission.catalog);
    });

    test('rejects an incomplete payload instead of guessing', () {
      expect(() => StaffContext.fromJson({'status': 'active'}), throwsFormatException);
      expect(
        () => StaffContext.fromJson({
          ...staffPayload(),
          'profile': {'full_name': 'No uid', 'role': 'staff'},
        }),
        throwsFormatException,
      );
      final noPermissions = staffPayload()..remove('permissions');
      expect(() => StaffContext.fromJson(noPermissions), throwsFormatException);
      final noBranches = staffPayload()..remove('authorized_branches');
      expect(() => StaffContext.fromJson(noBranches), throwsFormatException);
    });

    test('an unknown role is reported as an invalid role, never defaulted', () {
      expect(
        () => StaffContext.fromJson(staffPayload(role: 'admin')),
        throwsA(isA<InvalidStaffRoleException>()),
      );
    });

    test('staff without a branch, or whose branch is not authorized, are invalid', () {
      expect(
        () => StaffContext.fromJson(staffPayload(branchId: null)),
        throwsA(isA<InvalidStaffBranchException>()),
      );
      expect(
        () => StaffContext.fromJson(staffPayload(branches: [
          {'id': 'some-other-branch', 'name': 'Other'},
        ])),
        throwsA(isA<InvalidStaffBranchException>()),
      );
    });

    test('toJson/fromJson round-trips what the offline cache stores', () {
      final original = StaffContext.fromJson(staffPayload(refunds: true));
      final copy = StaffContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(original.toJson())) as Map),
      );
      expect(copy.firebaseUid, original.firebaseUid);
      expect(copy.permissions, original.permissions);
      expect(copy.authorizedBranches, original.authorizedBranches);
      expect(copy.profile.accountStatus, 'active');
      expect(copy.branchId, original.branchId);
    });
  });

  group('StaffProfileRepository.parseContext', () {
    test('an active account yields its context', () {
      final result = StaffProfileRepository.parseContext(staffPayload(), expectedUid: 'staff-a');
      expect(result.status, StaffContextStatus.active);
      expect(result.context!.firebaseUid, 'staff-a');
    });

    test('each non-active server status maps to its own result with no context', () {
      const expected = {
        'not_provisioned': StaffContextStatus.notProvisioned,
        'inactive': StaffContextStatus.inactive,
        'suspended': StaffContextStatus.suspended,
        'invalid_branch': StaffContextStatus.invalidBranch,
      };
      expected.forEach((serverStatus, status) {
        final result = StaffProfileRepository.parseContext({'status': serverStatus}, expectedUid: 'x');
        expect(result.status, status, reason: serverStatus);
        expect(result.context, isNull, reason: serverStatus);
      });
    });

    test('an unknown role and a branchless staff profile are classified, not errors', () {
      expect(
        StaffProfileRepository.parseContext(staffPayload(role: 'admin'), expectedUid: 'staff-a').status,
        StaffContextStatus.invalidRole,
      );
      expect(
        StaffProfileRepository.parseContext(staffPayload(branchId: null), expectedUid: 'staff-a').status,
        StaffContextStatus.invalidBranch,
      );
    });

    test('an answer for a different account is rejected, never attributed', () {
      expect(
        () => StaffProfileRepository.parseContext(staffPayload(uid: 'staff-b'), expectedUid: 'staff-a'),
        throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.authExpired)),
      );
    });

    test('garbage is a safe invalid-data error', () {
      for (final bad in <Object?>[null, 'oops', 42, <String, dynamic>{}, {'status': 'who-knows'}]) {
        expect(
          () => StaffProfileRepository.parseContext(bad, expectedUid: 'staff-a'),
          throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.invalidData)),
          reason: '$bad',
        );
      }
    });

    test('fetchMyContext calls the context RPC and parses the answer', () async {
      String? called;
      final repo = StaffProfileRepository.withRpc((fn) async {
        called = fn;
        return staffPayload();
      });
      final result = await repo.fetchMyContext(expectedUid: 'staff-a');
      expect(called, 'get_my_staff_context');
      expect(result.status, StaffContextStatus.active);
    });

    test('a network failure surfaces as a safe connectivity error', () async {
      final repo = StaffProfileRepository.withRpc((_) async => throw const SocketException('host lookup failed'));
      await expectLater(
        repo.fetchMyContext(expectedUid: 'staff-a'),
        throwsA(isA<AppError>().having((e) => e.isConnectivity, 'isConnectivity', isTrue)),
      );
    });

    test('syncMyIdentity never throws, even when the call fails', () async {
      final repo = StaffProfileRepository.withRpc((_) async => throw StateError('boom'));
      await repo.syncMyIdentity();
    });
  });

  group('safe error messages', () {
    String lower(AppError e) => e.message.toLowerCase();

    test('Firebase credential failures do not expose Firebase internals', () {
      final e = AppErrors.from(FirebaseAuthException(code: 'wrong-password', message: 'internal detail'));
      expect(lower(e), isNot(contains('firebase')));
      expect(lower(e), isNot(contains('internal detail')));
    });

    test('a Firebase network failure is a connectivity error', () {
      final e = AppErrors.from(FirebaseAuthException(code: 'network-request-failed'));
      expect(e.isConnectivity, isTrue);
    });

    test('SQLite failures become a safe local-storage error without SQL', () {
      final e = AppErrors.from(StateError('DatabaseException(no such table: staff_cache) sql SELECT * FROM staff_cache'));
      expect(e.kind, AppErrorKind.localStorage);
      expect(lower(e), isNot(contains('select')));
      expect(lower(e), isNot(contains('staff_cache')));
    });

    test('every staff access state has a fixed, backend-free message', () {
      final all = [
        AppErrors.staffNotProvisioned(),
        AppErrors.accountInactive(),
        AppErrors.accountSuspended(),
        AppErrors.invalidRole(),
        AppErrors.invalidBranch(),
        AppErrors.accessDenied(),
        AppErrors.localStorageError(),
      ];
      for (final e in all) {
        expect(e.message, isNotEmpty);
        for (final leak in ['supabase', 'firebase', 'postgres', 'sql', 'exception', 'stack']) {
          expect(lower(e), isNot(contains(leak)), reason: '${e.kind}');
        }
      }
      expect(all.map((e) => e.kind).toSet().length, all.length, reason: 'kinds are distinct');
    });
  });

  group('SupabaseConfig.isPrivilegedKey', () {
    test('flags a service_role JWT', () {
      expect(SupabaseConfig.isPrivilegedKey(_jwtWithRole('service_role')), isTrue);
    });

    test('flags a new-style secret key', () {
      expect(SupabaseConfig.isPrivilegedKey('sb_secret_abc123'), isTrue);
    });

    test('allows the anon JWT and a publishable key', () {
      expect(SupabaseConfig.isPrivilegedKey(_jwtWithRole('anon')), isFalse);
      expect(SupabaseConfig.isPrivilegedKey('sb_publishable_abc123'), isFalse);
    });

    test('does not throw on garbage or empty input', () {
      expect(SupabaseConfig.isPrivilegedKey(''), isFalse);
      expect(SupabaseConfig.isPrivilegedKey('a.b.c'), isFalse);
      expect(SupabaseConfig.isPrivilegedKey('not a key'), isFalse);
    });
  });
}
