import 'dart:math';

import 'package:sqflite_common/sqlite_api.dart';

import '../../core/services/sqlite_service.dart';
import '../../core/utils/app_error.dart';
import '../models/sync_operation.dart';

/// Persistent queue of operations waiting to reach Supabase (SQLite table
/// `sync_operations`).
///
/// OWNERSHIP: every operation belongs to one Firebase UID and EVERY query here
/// is scoped to a UID. Staff B can therefore never read, send, retry or
/// discard Staff A's operations, even on a shared device.
///
/// NEVER SILENTLY LOST: cleanup only ever deletes operations the server has
/// already accepted ([SyncStatus.synced]). Unsent ([SyncStatus.pending]) and
/// refused ([SyncStatus.failed]) operations stay until they sync or a person
/// explicitly discards them.
class SyncQueueRepository {
  SyncQueueRepository({
    Future<Database> Function()? database,
    DateTime Function()? now,
    Random? random,
  })  : _database = database ?? SqliteService.instance.open,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  static final SyncQueueRepository instance = SyncQueueRepository();

  final Future<Database> Function() _database;
  final DateTime Function() _now;
  final Random _random;

  static const String _table = 'sync_operations';

  Future<T> _guard<T>(Future<T> Function(Database db) action) async {
    try {
      return await action(await _database());
    } catch (e) {
      if (e is AppError) rethrow;
      throw AppErrors.from(e);
    }
  }

  String _newId() {
    final time = _now().microsecondsSinceEpoch.toRadixString(36);
    final noise = _random.nextInt(1 << 31).toRadixString(36);
    return 'op-$time-$noise';
  }

  /// Adds an operation for [staffFirebaseUid] and returns it. The returned
  /// [SyncOperation.localOperationId] is also the idempotency key to send to
  /// the server, so a retry after an ambiguous failure cannot apply twice.
  Future<SyncOperation> enqueue({
    required String staffFirebaseUid,
    required String operationType,
    required String entityType,
    required Map<String, dynamic> payload,
    String? entityId,
    String? localOperationId,
  }) {
    if (staffFirebaseUid.isEmpty || operationType.isEmpty || entityType.isEmpty) {
      throw ArgumentError('uid, operationType and entityType are required.');
    }
    final op = SyncOperation(
      localOperationId: localOperationId ?? _newId(),
      staffFirebaseUid: staffFirebaseUid,
      operationType: operationType,
      entityType: entityType,
      entityId: entityId,
      payload: payload,
      createdAt: _now(),
    );
    return _guard((db) async {
      await db.insert(_table, op.toMap());
      return op;
    });
  }

  Future<SyncOperation?> byId(String staffFirebaseUid, String localOperationId) {
    return _guard((db) async {
      final rows = await db.query(
        _table,
        where: 'staff_firebase_uid = ? AND local_operation_id = ?',
        whereArgs: [staffFirebaseUid, localOperationId],
        limit: 1,
      );
      return rows.isEmpty ? null : SyncOperation.fromMap(rows.first);
    });
  }

  /// Operations of one status for [staffFirebaseUid], oldest first (the order
  /// they must be sent in).
  Future<List<SyncOperation>> withStatus(
    String staffFirebaseUid,
    SyncStatus status, {
    int? limit,
  }) {
    return _guard((db) async {
      final rows = await db.query(
        _table,
        where: 'staff_firebase_uid = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, status.name],
        orderBy: 'created_at ASC, local_operation_id ASC',
        limit: limit,
      );
      return rows.map(SyncOperation.fromMap).toList(growable: false);
    });
  }

  Future<Map<SyncStatus, int>> countsByStatus(String staffFirebaseUid) {
    return _guard((db) async {
      final rows = await db.rawQuery(
        'SELECT sync_status AS status, COUNT(*) AS n FROM $_table '
        'WHERE staff_firebase_uid = ? GROUP BY sync_status',
        [staffFirebaseUid],
      );
      final counts = {for (final s in SyncStatus.values) s: 0};
      for (final row in rows) {
        counts[SyncStatus.parse(row['status'])] = (row['n'] as int?) ?? 0;
      }
      return counts;
    });
  }

  Future<void> markSyncing(String staffFirebaseUid, String localOperationId) {
    return _update(staffFirebaseUid, localOperationId, {
      'sync_status': SyncStatus.syncing.name,
      'last_attempt_at': _now().millisecondsSinceEpoch,
    });
  }

  Future<void> markSynced(String staffFirebaseUid, String localOperationId) {
    return _update(staffFirebaseUid, localOperationId, {
      'sync_status': SyncStatus.synced.name,
      'last_error': null,
    });
  }

  /// Puts an operation back in line after a transient failure (no network,
  /// timeout). Counts the attempt. [error] must already be a safe message.
  Future<void> markRetry(String staffFirebaseUid, String localOperationId, String error) {
    return _guard((db) async {
      await db.rawUpdate(
        'UPDATE $_table SET sync_status = ?, retry_count = retry_count + 1, '
        'last_error = ?, last_attempt_at = ? '
        'WHERE staff_firebase_uid = ? AND local_operation_id = ?',
        [
          SyncStatus.pending.name,
          error,
          _now().millisecondsSinceEpoch,
          staffFirebaseUid,
          localOperationId,
        ],
      );
    });
  }

  /// Marks an operation as refused / out of retries. [error] must already be a
  /// safe, person-readable message.
  Future<void> markFailed(String staffFirebaseUid, String localOperationId, String error) {
    return _guard((db) async {
      await db.rawUpdate(
        'UPDATE $_table SET sync_status = ?, retry_count = retry_count + 1, '
        'last_error = ?, last_attempt_at = ? '
        'WHERE staff_firebase_uid = ? AND local_operation_id = ?',
        [
          SyncStatus.failed.name,
          error,
          _now().millisecondsSinceEpoch,
          staffFirebaseUid,
          localOperationId,
        ],
      );
    });
  }

  /// A person chose to try a failed operation again.
  Future<void> requeueFailed(String staffFirebaseUid, String localOperationId) {
    return _guard((db) async {
      await db.update(
        _table,
        {'sync_status': SyncStatus.pending.name},
        where: 'staff_firebase_uid = ? AND local_operation_id = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, localOperationId, SyncStatus.failed.name],
      );
    });
  }

  /// A person chose to throw a failed operation away. Only failed operations
  /// can be discarded; pending ones are never deleted by this.
  Future<void> discardFailed(String staffFirebaseUid, String localOperationId) {
    return _guard((db) async {
      await db.delete(
        _table,
        where: 'staff_firebase_uid = ? AND local_operation_id = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, localOperationId, SyncStatus.failed.name],
      );
    });
  }

  /// After a crash or a force-quit mid-send, anything left in `syncing` goes
  /// back to `pending` (the server's idempotency key makes a re-send safe).
  Future<void> recoverInterrupted(String staffFirebaseUid) {
    return _guard((db) async {
      await db.update(
        _table,
        {'sync_status': SyncStatus.pending.name},
        where: 'staff_firebase_uid = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, SyncStatus.syncing.name],
      );
    });
  }

  /// Housekeeping that is safe at sign-out: drops operations the server
  /// already accepted and recovers interrupted ones. Unsent and failed
  /// operations are KEPT (see class doc).
  Future<void> tidyForSignOut(String staffFirebaseUid) {
    return _guard((db) async {
      await db.delete(
        _table,
        where: 'staff_firebase_uid = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, SyncStatus.synced.name],
      );
      await db.update(
        _table,
        {'sync_status': SyncStatus.pending.name},
        where: 'staff_firebase_uid = ? AND sync_status = ?',
        whereArgs: [staffFirebaseUid, SyncStatus.syncing.name],
      );
    });
  }

  Future<void> _update(String uid, String id, Map<String, Object?> values) {
    return _guard((db) async {
      await db.update(
        _table,
        values,
        where: 'staff_firebase_uid = ? AND local_operation_id = ?',
        whereArgs: [uid, id],
      );
    });
  }
}
