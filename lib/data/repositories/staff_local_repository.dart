import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../core/services/sqlite_service.dart';
import '../../core/utils/app_error.dart';
import '../models/staff_context.dart';

/// A previously server-validated staff context read back from disk.
class CachedStaffContext {
  final StaffContext context;

  /// When the SERVER last confirmed this context (not when it was read).
  final DateTime validatedAt;

  const CachedStaffContext(this.context, this.validatedAt);
}

/// The offline copy of the signed-in staff member's context (profile,
/// permissions, branch access), keyed by Firebase UID.
///
/// WHAT THIS IS FOR: letting a person who was ALREADY signed in to Firebase
/// (the Firebase SDK persists that session; this app never stores a password)
/// open the app without a network and keep reading.
///
/// WHAT IT IS NOT: an authority. Rules enforced here:
///  * a cached row is only returned for the exact UID asked for;
///  * only `active` contexts are stored, and a revoked / suspended / missing
///    account has its row DELETED (see [clearContext]) so it can never be
///    restored offline;
///  * a row older than [maxOfflineAge], dated in the future (clock tampering),
///    or that no longer parses is treated as absent;
///  * callers must treat a cache-backed session as NOT server-validated:
///    sensitive actions wait for the backend (see `StaffSessionStore`).
class StaffLocalRepository {
  StaffLocalRepository({
    Future<Database> Function()? database,
    DateTime Function()? now,
  })  : _database = database ?? SqliteService.instance.open,
        _now = now ?? DateTime.now;

  static final StaffLocalRepository instance = StaffLocalRepository();

  /// How long an offline session may keep working without the server having
  /// re-confirmed it. After this the person must reconnect once.
  static const Duration maxOfflineAge = Duration(hours: 72);

  /// Allowed clock skew when checking that a stored timestamp is not in the future.
  static const Duration _skew = Duration(minutes: 5);

  final Future<Database> Function() _database;
  final DateTime Function() _now;

  Future<T> _guard<T>(Future<T> Function(Database db) action) async {
    try {
      return await action(await _database());
    } catch (e) {
      if (e is AppError) rethrow;
      throw AppErrors.from(e);
    }
  }

  /// Stores [context] as the latest server-confirmed copy for its UID.
  /// A context that is not `active` is never stored; it clears the row instead.
  Future<void> saveContext(StaffContext context) {
    if (context.profile.accountStatus != 'active') {
      return clearContext(context.firebaseUid);
    }
    return _guard((db) async {
      final now = _now().millisecondsSinceEpoch;
      await db.insert(
        'staff_cache',
        {
          'firebase_uid': context.firebaseUid,
          'context_json': jsonEncode(context.toJson()),
          'account_status': context.profile.accountStatus,
          'role': context.profile.role,
          'branch_id': context.profile.branchId,
          'validated_at': context.loadedAt.millisecondsSinceEpoch,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// The cached context for [uid], or null when there is none that may be used.
  Future<CachedStaffContext?> loadContext(String uid, {Duration? maxAge}) {
    return _guard((db) async {
      final rows = await db.query(
        'staff_cache',
        where: 'firebase_uid = ?',
        whereArgs: [uid],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;

      final validatedAt = DateTime.fromMillisecondsSinceEpoch(row['validated_at'] as int);
      final now = _now();
      final tooOld = now.difference(validatedAt) > (maxAge ?? maxOfflineAge);
      final fromFuture = validatedAt.isAfter(now.add(_skew));
      if (tooOld || fromFuture || row['account_status'] != 'active') {
        await db.delete('staff_cache', where: 'firebase_uid = ?', whereArgs: [uid]);
        return null;
      }

      try {
        final decoded = jsonDecode(row['context_json'] as String);
        final context = StaffContext.fromJson(
          Map<String, dynamic>.from(decoded as Map),
          loadedAt: validatedAt,
        );
        if (context.firebaseUid != uid || context.profile.accountStatus != 'active') {
          throw const FormatException('Cached context belongs to someone else.');
        }
        return CachedStaffContext(context, validatedAt);
      } catch (e) {
        // Corrupt or tampered: forget it rather than trust it.
        if (kDebugMode) debugPrint('Discarding unreadable staff cache: ${e.runtimeType}');
        await db.delete('staff_cache', where: 'firebase_uid = ?', whereArgs: [uid]);
        return null;
      }
    });
  }

  /// Forgets [uid]'s cached context (sign-out, revoked / suspended account).
  Future<void> clearContext(String uid) {
    return _guard((db) async {
      await db.delete('staff_cache', where: 'firebase_uid = ?', whereArgs: [uid]);
    });
  }

  /// Deletes every cached context except [uid]'s. Run whenever a different
  /// account signs in, so nobody's cached access outlives their session on a
  /// shared device.
  Future<void> keepOnly(String uid) {
    return _guard((db) async {
      await db.delete('staff_cache', where: 'firebase_uid <> ?', whereArgs: [uid]);
    });
  }

  Future<void> clearAll() {
    return _guard((db) async {
      await db.delete('staff_cache');
    });
  }
}
