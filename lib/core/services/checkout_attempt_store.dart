import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/order.dart';
import '../../data/repositories/orders_repository.dart';

/// One checkout attempt: the idempotency key that identifies it to the
/// server, and whether its request has (possibly) left the device.
class CheckoutAttempt {
  final String key;
  final String uid;
  final String cartId;
  final DateTime createdAt;

  /// What this attempt asked the server for (fulfilment, address, payment
  /// method, notes). The server answers a repeated key with the FIRST order
  /// it stored for that key and never compares the request, so a key must
  /// only ever be reused for the identical request. Null for attempts saved
  /// by an older app version; those are never reused for a new request.
  final String? fingerprint;

  /// True once the `place_order` request was sent. From then until the
  /// server's answer is known, the outcome is UNKNOWN — the order may or may
  /// not exist — and the attempt must survive an app restart.
  final bool submitted;

  const CheckoutAttempt({
    required this.key,
    required this.uid,
    required this.cartId,
    required this.createdAt,
    this.fingerprint,
    this.submitted = false,
  });

  CheckoutAttempt copyWith({bool? submitted}) => CheckoutAttempt(
        key: key,
        uid: uid,
        cartId: cartId,
        createdAt: createdAt,
        fingerprint: fingerprint,
        submitted: submitted ?? this.submitted,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'uid': uid,
        'cartId': cartId,
        'createdAt': createdAt.toIso8601String(),
        'fingerprint': fingerprint,
        'submitted': submitted,
      };

  factory CheckoutAttempt.fromJson(Map<String, dynamic> json) => CheckoutAttempt(
        key: json['key'] as String,
        uid: json['uid'] as String,
        cartId: json['cartId'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        fingerprint: json['fingerprint'] as String?,
        submitted: json['submitted'] as bool? ?? false,
      );
}

/// Thrown by [CheckoutAttemptStore.begin] when the customer changed their
/// checkout options after a request whose outcome was unknown, and the server
/// turns out to have accepted that earlier request. The earlier order is the
/// real one; the screen should show it instead of placing another.
class CheckoutAlreadyPlacedException implements Exception {
  final Order order;
  const CheckoutAlreadyPlacedException(this.order);

  @override
  String toString() => 'CheckoutAlreadyPlacedException(${order.id})';
}

/// Where the single in-flight attempt is persisted.
abstract class CheckoutAttemptStorage {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> remove();
}

class _PrefsCheckoutAttemptStorage implements CheckoutAttemptStorage {
  static const String _storageKey = 'melai_checkout_attempt_v1';
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> read() => _prefs.getString(_storageKey);
  @override
  Future<void> write(String value) => _prefs.setString(_storageKey, value);
  @override
  Future<void> remove() => _prefs.remove(_storageKey);
}

/// Makes "Place Order" safe to retry — including after the connection
/// drops mid-request or the app is killed — without ever creating two
/// orders or claiming an order that the server did not accept.
///
/// How:
///  1. [begin] hands out ONE idempotency key per (customer, cart, request)
///     and saves it to disk. Every retry of the SAME request reuses the same
///     key, and the `place_order` database function returns the existing
///     order for a key it has already seen instead of creating another. The
///     server does not compare the request on a repeated key, so if the
///     customer changes their options after a request whose outcome is
///     unknown, [begin] first asks the server whether that request was
///     accepted (throwing [CheckoutAlreadyPlacedException] if so) and only
///     otherwise mints a new key.
///  2. [markSubmitted] is called right before the request is sent.
///  3. On success [clear] is called. On a definitive server rejection
///     [clear] is called too (nothing was created; a later attempt is new).
///     On a transient failure the attempt is KEPT — the outcome is unknown.
///  4. [resolveUnconfirmed] runs whenever customer data loads while online:
///     if a submitted attempt exists it asks the server whether an order with
///     that key exists. If yes, the order really was accepted (see
///     [recoveredOrder]); if not, nothing was placed and a retry with the
///     same key remains safe.
class CheckoutAttemptStore extends ChangeNotifier {
  CheckoutAttemptStore._()
      : this.withDependencies(
          storage: _PrefsCheckoutAttemptStorage(),
          lookup: (uid, key) => OrdersRepository.instance.findByIdempotencyKey(uid, key),
        );

  @visibleForTesting
  CheckoutAttemptStore.withDependencies({
    required this._storage,
    required this._lookup,
    DateTime Function()? now,
    String Function()? newKey,
  })  : _now = now ?? DateTime.now,
        _newKeyFn = newKey;

  static final CheckoutAttemptStore instance = CheckoutAttemptStore._();

  static const Duration _maxAge = Duration(hours: 24);

  final CheckoutAttemptStorage _storage;
  final Future<Order?> Function(String uid, String key) _lookup;
  final DateTime Function() _now;
  final String Function()? _newKeyFn;

  /// Set when an earlier, unconfirmed checkout turned out to have been
  /// accepted by the server. The UI shows it once, then [dismissRecovered].
  Order? recoveredOrder;

  Future<CheckoutAttempt?> _read() async {
    try {
      final raw = await _storage.read();
      if (raw == null || raw.isEmpty) return null;
      return CheckoutAttempt.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(CheckoutAttempt attempt) async {
    try {
      await _storage.write(jsonEncode(attempt.toJson()));
    } catch (_) {
      // If the disk write fails the attempt still works for this session.
    }
  }

  /// The attempt to use for this exact request ([fingerprint]) on [cartId]:
  /// the saved one if it belongs to this customer and cart, is recent, and
  /// asked for the identical request; otherwise a brand-new key.
  ///
  /// If the saved attempt was already sent (outcome unknown) but the request
  /// has since changed, the server is asked about the old key first, because
  /// it may have accepted that order. Throws [CheckoutAlreadyPlacedException]
  /// if it did. If the server can't be reached the lookup error propagates and
  /// the saved attempt is kept: with the outcome unknown, a new key could
  /// place a second order.
  Future<CheckoutAttempt> begin({
    required String uid,
    required String cartId,
    required String fingerprint,
  }) async {
    final existing = await _read();
    final usable = existing != null &&
        existing.uid == uid &&
        existing.cartId == cartId &&
        _now().difference(existing.createdAt) < _maxAge;
    if (usable && existing.fingerprint == fingerprint) return existing;

    if (usable && existing.submitted) {
      final placed = await _lookup(uid, existing.key);
      if (placed != null) {
        await clear();
        throw CheckoutAlreadyPlacedException(placed);
      }
    }

    final fresh = CheckoutAttempt(
      key: _newKey(),
      uid: uid,
      cartId: cartId,
      createdAt: _now(),
      fingerprint: fingerprint,
    );
    await _write(fresh);
    return fresh;
  }

  Future<void> markSubmitted(CheckoutAttempt attempt) => _write(attempt.copyWith(submitted: true));

  Future<void> clear() async {
    try {
      await _storage.remove();
    } catch (_) {}
  }

  /// Settles a checkout whose outcome was never seen. Only call while
  /// online. Throws if the server can't be reached (the attempt is kept).
  Future<void> resolveUnconfirmed(String uid) async {
    final attempt = await _read();
    if (attempt == null) return;
    if (attempt.uid != uid || _now().difference(attempt.createdAt) >= _maxAge) {
      await clear();
      return;
    }
    if (!attempt.submitted) return;

    final order = await _lookup(uid, attempt.key);
    if (order == null) return; // never accepted; a same-key retry is safe
    await clear();
    recoveredOrder = order;
    notifyListeners();
  }

  void dismissRecovered() {
    if (recoveredOrder == null) return;
    recoveredOrder = null;
    notifyListeners();
  }

  /// Forget everything (sign-out).
  Future<void> reset() async {
    recoveredOrder = null;
    await clear();
    notifyListeners();
  }

  String _newKey() {
    final injected = _newKeyFn;
    if (injected != null) return injected();
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'co-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}
