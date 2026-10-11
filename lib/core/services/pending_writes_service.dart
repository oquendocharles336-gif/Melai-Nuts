import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/customer_profile_repository.dart';
import '../../data/repositories/notifications_repository.dart';
import 'connectivity_service.dart';
import 'network_errors.dart';

/// The ONLY customer writes that may wait offline. Each is idempotent and
/// last-write-wins, so replaying it later — or twice — is harmless.
///
/// Deliberately NOT here (they need the server's answer *now*, and must
/// never appear to succeed while offline): placing an order / payment
/// (see `CheckoutAttemptStore` for how retries stay duplicate-free),
/// redeeming a reward (spends points), submitting a refund request, and
/// address-book changes (new rows need server-assigned ids).
enum PendingWriteKind {
  notificationMarkRead,
  notificationMarkAllRead,
  notificationDelete,
  notificationPreferences,
  profileUpdate,
}

/// `pending`: waiting for a connection / a retry.
/// `failed`: the server answered and rejected it; needs the customer to
/// retry or discard (it is never silently dropped and never auto-retried).
enum PendingWriteStatus { pending, failed }

enum WriteOutcomeKind {
  /// The server accepted the write.
  synced,

  /// Not confirmed by the server yet; saved on this device and will sync.
  queued,

  /// The server answered and refused it. Nothing was saved.
  rejected,
}

class WriteOutcome {
  final WriteOutcomeKind kind;
  final String? message;

  /// Server result when [kind] is [WriteOutcomeKind.synced] (e.g. the updated
  /// `CustomerProfile` for a profile update); otherwise null.
  final Object? result;

  const WriteOutcome(this.kind, {this.message, this.result});
}

class PendingWrite {
  final String id;
  final String uid;
  final PendingWriteKind kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  int attempts;
  PendingWriteStatus status;
  String? lastError;

  /// In-memory only: set once the server has accepted this write.
  bool done = false;

  PendingWrite({
    required this.id,
    required this.uid,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
    this.status = PendingWriteStatus.pending,
    this.lastError,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'uid': uid,
        'kind': kind.name,
        'payload': payload,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        'status': status.name,
        'lastError': lastError,
      };

  factory PendingWrite.fromJson(Map<String, dynamic> json) {
    return PendingWrite(
      id: json['id'] as String,
      uid: json['uid'] as String,
      kind: PendingWriteKind.values.byName(json['kind'] as String),
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      createdAt: DateTime.parse(json['createdAt'] as String),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      status: PendingWriteStatus.values.byName(json['status'] as String),
      lastError: json['lastError'] as String?,
    );
  }
}

/// Durable outbox for [PendingWriteKind] writes.
///
/// Every write is saved to disk first, then attempted. The caller is told
/// the truth via [WriteOutcome]: `synced` only if the server accepted it,
/// `queued` if it is merely stored on this device, `rejected` if the server
/// said no. Queued writes are flushed (in order) when connectivity returns
/// and whenever customer data is refreshed; a server rejection during a
/// later flush marks the write `failed` and surfaces it to the customer.
class PendingWritesService extends ChangeNotifier {
  PendingWritesService._();
  static final PendingWritesService instance = PendingWritesService._();

  static const String _storageKey = 'melai_pending_writes_v1';
  static const Duration _retryDelay = Duration(seconds: 30);

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  final List<PendingWrite> _items = [];
  Future<void>? _loading;
  Future<void>? _flushing;
  Timer? _retryTimer;

  /// Loads the persisted queue. Call once at startup; every other method also
  /// awaits it, so ordering is safe either way.
  Future<void> init() => _ensureLoaded();

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        for (final entry in jsonDecode(raw) as List) {
          try {
            _items.add(PendingWrite.fromJson(Map<String, dynamic>.from(entry as Map)));
          } catch (_) {
            // Skip one corrupt entry rather than losing the whole queue.
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _prefs.setString(_storageKey, jsonEncode([for (final w in _items) w.toJson()]));
    } catch (_) {}
  }

  // ---- Counts / overlays (synchronous; used by the UI) -------------------

  int pendingCount(String uid) =>
      _items.where((w) => w.uid == uid && w.status == PendingWriteStatus.pending).length;

  int failedCount(String uid) =>
      _items.where((w) => w.uid == uid && w.status == PendingWriteStatus.failed).length;

  Iterable<PendingWrite> _pending(String uid, PendingWriteKind kind) => _items.where(
        (w) => w.uid == uid && w.kind == kind && w.status == PendingWriteStatus.pending,
      );

  Set<String> pendingNotificationReadIds(String uid) => {
        for (final w in _pending(uid, PendingWriteKind.notificationMarkRead)) w.payload['id'] as String,
      };

  Set<String> pendingNotificationDeleteIds(String uid) => {
        for (final w in _pending(uid, PendingWriteKind.notificationDelete)) w.payload['id'] as String,
      };

  bool hasPendingMarkAllRead(String uid) =>
      _pending(uid, PendingWriteKind.notificationMarkAllRead).isNotEmpty;

  Map<String, bool>? pendingPreferences(String uid) {
    for (final w in _pending(uid, PendingWriteKind.notificationPreferences)) {
      return Map<String, bool>.from(w.payload['prefs'] as Map);
    }
    return null;
  }

  Map<String, dynamic>? pendingProfileUpdate(String uid) {
    for (final w in _pending(uid, PendingWriteKind.profileUpdate)) {
      return Map<String, dynamic>.from(w.payload);
    }
    return null;
  }

  // ---- Writing -----------------------------------------------------------

  /// Saves the write durably, then tries to apply it now.
  ///
  /// Returns:
  ///  * `synced`   — the server accepted it.
  ///  * `queued`   — offline / server unreachable; kept and will be retried.
  ///  * `rejected` — the server refused it; it is NOT kept.
  Future<WriteOutcome> run(
    String uid,
    PendingWriteKind kind,
    Map<String, dynamic> payload,
  ) async {
    await _ensureLoaded();
    final write = await _enqueue(uid, kind, payload);

    if (ConnectivityService.instance.isOnline) {
      await flush(uid);
      // A flush that was already running may have started before this write
      // was added; run once more so it is not left waiting for no reason.
      if (!write.done &&
          write.status == PendingWriteStatus.pending &&
          _items.contains(write) &&
          ConnectivityService.instance.isOnline) {
        await flush(uid);
      }
    }

    if (write.done) return WriteOutcome(WriteOutcomeKind.synced, result: _results.remove(write.id));
    if (write.status == PendingWriteStatus.failed) {
      _items.remove(write);
      await _persist();
      notifyListeners();
      return WriteOutcome(WriteOutcomeKind.rejected, message: write.lastError);
    }
    return const WriteOutcome(WriteOutcomeKind.queued);
  }

  final Map<String, Object?> _results = {};

  Future<PendingWrite> _enqueue(
    String uid,
    PendingWriteKind kind,
    Map<String, dynamic> payload,
  ) async {
    switch (kind) {
      case PendingWriteKind.notificationPreferences:
      case PendingWriteKind.profileUpdate:
        // Last write wins: an older queued copy is superseded.
        _items.removeWhere(
          (w) => w.uid == uid && w.kind == kind && w.status == PendingWriteStatus.pending,
        );
      case PendingWriteKind.notificationMarkRead:
        _items.removeWhere(
          (w) =>
              w.uid == uid &&
              w.kind == kind &&
              w.status == PendingWriteStatus.pending &&
              w.payload['id'] == payload['id'],
        );
      case PendingWriteKind.notificationDelete:
        // Deleting makes any queued read/delete for that id pointless.
        _items.removeWhere(
          (w) =>
              w.uid == uid &&
              w.status == PendingWriteStatus.pending &&
              (w.kind == PendingWriteKind.notificationMarkRead ||
                  w.kind == PendingWriteKind.notificationDelete) &&
              w.payload['id'] == payload['id'],
        );
      case PendingWriteKind.notificationMarkAllRead:
        _items.removeWhere(
          (w) => w.uid == uid && w.kind == kind && w.status == PendingWriteStatus.pending,
        );
    }
    final write = PendingWrite(
      id: _newId(),
      uid: uid,
      kind: kind,
      payload: payload,
      createdAt: DateTime.now(),
    );
    _items.add(write);
    await _persist();
    notifyListeners();
    return write;
  }

  String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$hex';
  }

  // ---- Flushing ----------------------------------------------------------

  /// Applies every `pending` write for [uid], oldest first. Single-flight.
  ///
  /// A transient failure (offline / 5xx / timeout) stops the run and keeps
  /// the remaining writes queued (a retry is scheduled). A definitive server
  /// rejection marks just that write `failed` and continues.
  Future<void> flush(String uid) {
    final running = _flushing;
    if (running != null) return running;
    final future = _flushInner(uid).whenComplete(() => _flushing = null);
    _flushing = future;
    return future;
  }

  Future<void> _flushInner(String uid) async {
    await _ensureLoaded();
    if (!ConnectivityService.instance.isOnline) return;

    final due = _items
        .where((w) => w.uid == uid && w.status == PendingWriteStatus.pending)
        .toList();
    var changed = false;
    var stoppedTransient = false;

    for (final write in due) {
      try {
        _results[write.id] = await _execute(write);
        write.done = true;
        _items.remove(write);
        changed = true;
      } catch (e) {
        write.attempts++;
        changed = true;
        if (isTransientFailure(e)) {
          write.lastError = describeError(e);
          stoppedTransient = true;
          break;
        }
        write.status = PendingWriteStatus.failed;
        write.lastError = describeError(e);
      }
    }

    if (changed) {
      await _persist();
      notifyListeners();
    }
    _retryTimer?.cancel();
    if (stoppedTransient) {
      _retryTimer = Timer(_retryDelay, () => unawaited(flush(uid)));
    }
  }

  Future<Object?> _execute(PendingWrite w) async {
    switch (w.kind) {
      case PendingWriteKind.notificationMarkRead:
        await NotificationsRepository.instance.markRead(w.payload['id'] as String);
        return null;
      case PendingWriteKind.notificationMarkAllRead:
        await NotificationsRepository.instance.markAllRead(w.uid);
        return null;
      case PendingWriteKind.notificationDelete:
        await NotificationsRepository.instance.delete(w.payload['id'] as String);
        return null;
      case PendingWriteKind.notificationPreferences:
        await NotificationsRepository.instance.savePreferences(
          w.uid,
          Map<String, bool>.from(w.payload['prefs'] as Map),
        );
        return null;
      case PendingWriteKind.profileUpdate:
        return CustomerProfileRepository.instance.updateProfile(
          firebaseUid: w.uid,
          fullName: w.payload['fullName'] as String,
          phone: w.payload['phone'] as String,
        );
    }
  }

  // ---- Customer actions on failed writes ---------------------------------

  Future<void> retryFailed(String uid) async {
    await _ensureLoaded();
    for (final w in _items) {
      if (w.uid == uid && w.status == PendingWriteStatus.failed) {
        w.status = PendingWriteStatus.pending;
        w.attempts = 0;
        w.lastError = null;
      }
    }
    await _persist();
    notifyListeners();
    await flush(uid);
  }

  Future<void> discardFailed(String uid) async {
    await _ensureLoaded();
    _items.removeWhere((w) => w.uid == uid && w.status == PendingWriteStatus.failed);
    await _persist();
    notifyListeners();
  }

  /// The first server error text among failed writes, for display.
  String? firstFailureMessage(String uid) {
    for (final w in _items) {
      if (w.uid == uid && w.status == PendingWriteStatus.failed) return w.lastError;
    }
    return null;
  }

  // ---- Session boundaries ------------------------------------------------

  /// Drops every queued write for [uid] (sign-out): a signed-out device must
  /// not keep a customer's unsynced data.
  Future<void> clearForUser(String uid) async {
    await _ensureLoaded();
    _retryTimer?.cancel();
    _items.removeWhere((w) => w.uid == uid);
    await _persist();
    notifyListeners();
  }

  /// Drops queued writes belonging to anyone other than [uid] (or everyone
  /// when [uid] is null). Called when the signed-in account changes.
  Future<void> keepOnlyUser(String? uid) async {
    await _ensureLoaded();
    final before = _items.length;
    _items.removeWhere((w) => w.uid != uid);
    if (_items.length != before) {
      await _persist();
      notifyListeners();
    }
  }
}
