import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/staff_context.dart';

/// What the server says about the signed-in account's staff standing.
enum StaffContextStatus {
  /// A staff profile exists and is active; [StaffContextResult.context] is set.
  active,

  /// A profile exists but an administrator deactivated it.
  inactive,

  /// An administrator suspended it.
  suspended,

  /// The account is signed in but no staff profile has been created for it.
  notProvisioned,

  /// The profile carries a role this app does not know.
  invalidRole,

  /// The profile has no usable branch assignment.
  invalidBranch,
}

class StaffContextResult {
  final StaffContextStatus status;
  final StaffContext? context;

  const StaffContextResult(this.status, [this.context]);
}

/// Reads the signed-in staff member's identity from Supabase.
///
/// Uses the existing shared Supabase client ([SupabaseService]), whose
/// `accessToken` hook attaches the caller's live Firebase ID token — the
/// server decides who is asking from that verified token, never from anything
/// this class sends.
///
/// Deliberately goes through the `get_my_staff_context()` RPC and NOT a table
/// read: `staff_members` is only readable for the caller's own row, and RPC
/// responses are never stored by the offline read cache, so permissions can't
/// be served stale from disk after an administrator revokes them.
class StaffProfileRepository {
  StaffProfileRepository._(this._rpc);
  static final StaffProfileRepository instance = StaffProfileRepository._(_supabaseRpc);

  /// Test seam: a repository whose RPC is supplied by the test.
  StaffProfileRepository.withRpc(Future<dynamic> Function(String fn) rpc) : _rpc = rpc;

  final Future<dynamic> Function(String fn) _rpc;

  static Future<dynamic> _supabaseRpc(String fn) =>
      SupabaseService.instance.client.rpc(fn);

  /// Fetches the caller's staff context. [expectedUid] is the Firebase UID the
  /// caller believes is signed in; if the server answers for a different
  /// account (a token swapped mid-request) the result is rejected instead of
  /// being attributed to the wrong person.
  ///
  /// Throws [AppError] (safe message) on network / auth / server failure.
  /// "Not provisioned", "inactive", "suspended" and the invalid-role/branch
  /// outcomes are normal results, not errors.
  Future<StaffContextResult> fetchMyContext({required String expectedUid}) async {
    final Object? raw = await AppErrors.guard<dynamic>(
      () => _rpc('get_my_staff_context'),
      scope: ErrorScope.profile,
      timeout: AppErrors.rpcTimeout,
    );
    return parseContext(raw, expectedUid: expectedUid);
  }

  /// Turns the RPC payload into a result. Pure (no I/O) so it is unit-tested.
  static StaffContextResult parseContext(Object? raw, {required String expectedUid}) {
    if (raw is! Map) throw _malformed();
    final json = Map<String, dynamic>.from(raw);

    switch (json['status']) {
      case 'not_provisioned':
        return const StaffContextResult(StaffContextStatus.notProvisioned);
      case 'inactive':
        return const StaffContextResult(StaffContextStatus.inactive);
      case 'suspended':
        return const StaffContextResult(StaffContextStatus.suspended);
      case 'invalid_branch':
        return const StaffContextResult(StaffContextStatus.invalidBranch);
      case 'active':
        final StaffContext context;
        try {
          context = StaffContext.fromJson(json);
        } on InvalidStaffRoleException {
          return const StaffContextResult(StaffContextStatus.invalidRole);
        } on InvalidStaffBranchException {
          return const StaffContextResult(StaffContextStatus.invalidBranch);
        } on FormatException {
          throw _malformed();
        } on TypeError {
          throw _malformed();
        }
        if (context.firebaseUid != expectedUid) {
          throw const AppError(
            AppErrorKind.authExpired,
            'Your session is out of date. Please sign in again.',
          );
        }
        return StaffContextResult(StaffContextStatus.active, context);
      default:
        throw _malformed();
    }
  }

  /// Best effort: asks the server to copy the verified Firebase email onto
  /// the registry row. The email comes from the token on the server, never
  /// from this call. Failures are ignored — it only keeps a display field fresh.
  Future<void> syncMyIdentity() async {
    try {
      await AppErrors.guard<dynamic>(
        () => _rpc('staff_sync_my_identity'),
        scope: ErrorScope.profile,
        timeout: AppErrors.queryTimeout,
      );
    } catch (_) {
      // Display-only; retried on the next successful validation.
    }
  }

  static AppError _malformed() => const AppError(
        AppErrorKind.invalidData,
        'We received some unexpected data. Please try again.',
      );
}
