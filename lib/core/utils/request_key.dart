import 'dart:math';

/// A random key that identifies ONE staff request to the server
/// (`p_idempotency_key` on `staff_adjust_batch` / `staff_request_transfer`).
/// 'rk-' + 32 hex chars, inside the server's 8–100 character limit.
String newRequestKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'rk-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Hands out one idempotency key per distinct request.
///
/// A form holds one of these. Tapping Submit again with the SAME inputs after
/// a timeout reuses the key, so the server applies the change once even if the
/// first attempt actually went through. Changing any input is a new request and
/// gets a new key (the server refuses a key reused for a different request).
///
/// If the first attempt did commit and the user then edits the inputs, the edit
/// is treated as a genuinely new action, so refresh the data after a failed
/// submit rather than assuming nothing happened.
class RequestKeyHolder {
  RequestKeyHolder({String Function()? generate}) : _generate = generate ?? newRequestKey;

  final String Function() _generate;
  String? _fingerprint;
  String? _key;

  /// The key for a request whose inputs serialize to [fingerprint].
  String keyFor(String fingerprint) {
    if (_key == null || _fingerprint != fingerprint) {
      _key = _generate();
      _fingerprint = fingerprint;
    }
    return _key!;
  }

  /// Forget the current key (e.g. after a confirmed success on a form that
  /// stays open).
  void reset() {
    _key = null;
    _fingerprint = null;
  }
}
