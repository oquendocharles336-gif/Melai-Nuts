import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/sync_operation.dart';
import '../../data/repositories/sync_queue_repository.dart';
import '../utils/app_error.dart';
import 'connectivity_service.dart';
import 'staff_session_store.dart';

/// Sends one queued operation to Supabase. Return normally when the server
/// ACCEPTED it. Use [SyncOperation.localOperationId] as the idempotency key so
/// a re-send after an ambiguous failure cannot apply twice.
///
/// Throw [SyncRejectedException] when the server understood and REFUSED it
/// (retrying cannot help). Any other error is classified by [AppErrors].
typedef SyncHandler = Future<void> Function(SyncOperation operation);

/// The server refused an operation for a reason retrying will not fix.
/// [message] must be safe to show to a person.
class SyncRejectedException implements Exception {
  final String message;
  const SyncRejectedException(this.message);

  @override
  String toString() => message;
}

/// Drains the SQLite operation queue ([SyncQueueRepository]) to Supabase.
///
/// Batch 1 provides the machinery only; later batches call
/// [registerHandler] for each `operationType` they define (inventory
/// adjustments, stock transfers, ...). An operation with no registered handler
/// is simply left pending — it is never failed or dropped for lack of one.
///
/// RULES
///  * Only runs for the signed-in staff member, only while online, and only
///    when the SERVER has confirmed that staff session
///    ([StaffSessionStore.isServerValidated]) — an offline, cache-backed
///    session never pushes anything.
///  * Operations go out oldest first, one at a time. A connectivity failure
///    stops the run (order is preserved) and the operation goes back to
///    pending for the next attempt.
///  * Refused operations become `failed` and stay for a person to retry or
///    discard. Operations of any other staff member are never touched.
class SyncService extends ChangeNotifier {
  SyncService._app()
      : this.create(
          queue: SyncQueueRepository.instance,
          currentUid: () => StaffSessionStore.instance.ownerUid,
          isServerValidated: () => StaffSessionStore.instance.isServerValidated,
          isOnline: () => ConnectivityService.instance.isOnline,
        );

  @visibleForTesting
  SyncService.create({
    required this._queue,
    required this._currentUid,
    required this._isServerValidated,
    required this._isOnline,
    this.maxAttempts = 5,
  });

  static final SyncService instance = SyncService._app();

  /// A non-connectivity failure is retried until this many attempts, then the
  /// operation is marked failed for a person to look at.
  final int maxAttempts;

  final SyncQueueRepository _queue;
  final String? Function() _currentUid;
  final bool Function() _isServerValidated;
  final bool Function() _isOnline;

  final Map<String, SyncHandler> _handlers = <String, SyncHandler>{};
  Future<void>? _running;
  bool _attached = false;

  int _pending = 0;
  int _failed = 0;
  AppError? _lastError;

  /// Operations waiting to be sent for the signed-in staff member.
  int get pendingCount => _pending;

  /// Operations the server refused (or that ran out of retries).
  int get failedCount => _failed;

  bool get isProcessing => _running != null;
  AppError? get lastError => _lastError;

  void registerHandler(String operationType, SyncHandler handler) {
    _handlers[operationType] = handler;
  }

  bool hasHandler(String operationType) => _handlers.containsKey(operationType);

  /// Starts following the staff session and connectivity: drains the queue
  /// whenever a server-confirmed session appears and whenever the connection
  /// returns. Call once at startup. Idempotent.
  void attach({
    required StaffSessionStore session,
    required ConnectivityService connectivity,
  }) {
    if (_attached) return;
    _attached = true;
    session.addListener(() {
      if (session.isServerValidated) {
        unawaited(refreshCounts());
        unawaited(processPending());
      }
    });
    connectivity.onReconnect(processPending);
  }

  /// Saves an operation for the signed-in staff member and tries to send it
  /// right away if the conditions allow. Always durable first: the returned
  /// operation is already on disk.
  Future<SyncOperation> enqueue({
    required String operationType,
    required String entityType,
    required Map<String, dynamic> payload,
    String? entityId,
    String? localOperationId,
  }) async {
    final uid = _currentUid();
    if (uid == null) throw AppErrors.accessDenied();
    final op = await _queue.enqueue(
      staffFirebaseUid: uid,
      operationType: operationType,
      entityType: entityType,
      payload: payload,
      entityId: entityId,
      localOperationId: localOperationId,
    );
    await refreshCounts();
    unawaited(processPending());
    return op;
  }

  /// Sends everything that can be sent right now. Safe to call at any time and
  /// from several places: overlapping calls share one run.
  Future<void> processPending() {
    return _running ??= _process().whenComplete(() {
      _running = null;
    });
  }

  Future<void> _process() async {
    final uid = _currentUid();
    if (uid == null || !_isOnline() || !_isServerValidated()) return;

    try {
      await _queue.recoverInterrupted(uid);
      final operations = await _queue.withStatus(uid, SyncStatus.pending);

      for (final op in operations) {
        // Stop the moment the account changes or the connection/session drops.
        if (_currentUid() != uid || !_isOnline() || !_isServerValidated()) break;

        final handler = _handlers[op.operationType];
        if (handler == null) continue; // a later batch will teach us this type

        await _queue.markSyncing(uid, op.localOperationId);
        try {
          await handler(op);
          await _queue.markSynced(uid, op.localOperationId);
        } on SyncRejectedException catch (e) {
          await _queue.markFailed(uid, op.localOperationId, e.message);
        } catch (e) {
          final error = AppErrors.from(e);
          if (!await _recordFailure(uid, op, error)) break;
        }
      }
      _lastError = null;
    } catch (e) {
      _lastError = AppErrors.from(e);
    } finally {
      await refreshCounts();
    }
  }

  /// Records a failed attempt. Returns false when the run should stop.
  Future<bool> _recordFailure(String uid, SyncOperation op, AppError error) async {
    final id = op.localOperationId;
    switch (error.kind) {
      case AppErrorKind.noInternet:
      case AppErrorKind.timeout:
      case AppErrorKind.authExpired:
        // Transient: try again later; keep order by stopping here.
        await _queue.markRetry(uid, id, error.message);
        return false;
      case AppErrorKind.permissionDenied:
      case AppErrorKind.accessDenied:
      case AppErrorKind.invalidData:
      case AppErrorKind.notFound:
        // The server will not accept this no matter how often it is sent.
        await _queue.markFailed(uid, id, error.message);
        return true;
      default:
        if (op.retryCount + 1 >= maxAttempts) {
          await _queue.markFailed(uid, id, error.message);
        } else {
          await _queue.markRetry(uid, id, error.message);
        }
        return true;
    }
  }

  /// Re-reads the counters for the signed-in staff member.
  Future<void> refreshCounts() async {
    final uid = _currentUid();
    if (uid == null) {
      _setCounts(0, 0);
      return;
    }
    try {
      final counts = await _queue.countsByStatus(uid);
      // The account may have changed while we read.
      if (_currentUid() != uid) return;
      _setCounts(
        (counts[SyncStatus.pending] ?? 0) + (counts[SyncStatus.syncing] ?? 0),
        counts[SyncStatus.failed] ?? 0,
      );
    } catch (_) {
      // Counters are informational.
    }
  }

  void _setCounts(int pending, int failed) {
    if (pending == _pending && failed == _failed) return;
    _pending = pending;
    _failed = failed;
    notifyListeners();
  }

  /// Best-effort push of queued work while the person is still signed in.
  /// Bounded so logging out can never hang.
  Future<void> flushBeforeSignOut({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      await processPending().timeout(timeout);
    } catch (_) {
      // Whatever could not be sent stays queued (it is never deleted here).
    }
  }

  /// Sign-out housekeeping for [uid]: drops what the server already accepted,
  /// keeps everything unsent or failed.
  Future<void> tidyForSignOut(String uid) async {
    try {
      await _queue.tidyForSignOut(uid);
    } catch (_) {
      // Housekeeping only.
    }
  }

  /// Forgets the in-memory view (counters, last error). The queue itself stays
  /// on disk, owned by its staff member. Register as a staff reset hook.
  void resetState() {
    _lastError = null;
    _setCounts(0, 0);
  }
}
