import 'dart:math';

/// The idempotency key for one POS checkout.
///
/// The database finds a replay by staff member + key and compares the
/// request: the same request returns the recorded sale; a DIFFERENT request
/// with the same key is refused ("This sale was already recorded with
/// different details."). So:
///
///  * The same request always reuses the key (a retry after a dropped
///    connection can never ring the sale up twice).
///  * When the items, customer, payment method or reference change after an
///    attempt the server definitely did NOT record (it answered with an
///    error), a new key is made, so the corrected sale goes through.
///  * Once any attempt ended with an unknown outcome (timeout / offline), the
///    key is kept for good: the server may already hold that sale, and only
///    the same key lets it say so instead of ringing up a second sale.
class PosSaleAttempt {
  PosSaleAttempt({String Function()? newKey}) : _newKey = newKey ?? randomKey {
    _key = _newKey();
  }

  final String Function() _newKey;
  late String _key;
  String? _sentFingerprint;
  bool _outcomeUnknown = false;

  /// The key the last request was (or the next unchanged one will be) sent with.
  String get currentKey => _key;

  /// The key to send for a request with [fingerprint] (see [fingerprintOf]).
  String keyFor(String fingerprint) {
    final sent = _sentFingerprint;
    if (sent != null && sent != fingerprint && !_outcomeUnknown) {
      _key = _newKey();
    }
    _sentFingerprint = fingerprint;
    return _key;
  }

  /// Call after a failed attempt. [outcomeUnknown] is true for connection
  /// failures and timeouts (the sale may have been recorded).
  void markFailed({required bool outcomeUnknown}) {
    if (outcomeUnknown) _outcomeUnknown = true;
  }

  /// What makes two requests "the same sale" — the same fields the database
  /// compares (cash received is left out, as there).
  static String fingerprintOf({
    required String branchId,
    required Map<String, int> cart,
    required String method,
    String? customerUid,
    String? reference,
  }) {
    final lines = <String, int>{};
    cart.forEach((variant, qty) {
      final id = variant.trim().toLowerCase();
      lines[id] = (lines[id] ?? 0) + qty;
    });
    final sorted = lines.keys.toList()..sort();
    return [
      branchId,
      method.trim().toLowerCase(),
      (customerUid == null || customerUid.trim().isEmpty) ? 'walk-in' : customerUid.trim(),
      reference?.trim() ?? '',
      sorted.map((v) => '${v}x${lines[v]}').join(','),
    ].join('|');
  }

  static String randomKey() {
    final r = Random.secure();
    final bytes = List<int>.generate(12, (_) => r.nextInt(256));
    return 'pos-${DateTime.now().microsecondsSinceEpoch}-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}
