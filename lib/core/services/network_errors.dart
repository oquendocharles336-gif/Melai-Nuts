import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_error.dart';

/// True when [error] means "we never got a definitive answer from the
/// server" — the connection dropped, timed out, or the gateway/server was
/// temporarily unavailable (HTTP 5xx, expired token that will be refreshed).
///
/// This distinction drives what the customer app is allowed to claim:
///
///   * transient failure  -> the request MAY or MAY NOT have been applied.
///     Safe writes stay queued/retryable; an order is never reported as
///     placed, and a retry must reuse the same idempotency key.
///   * anything else      -> the server (or its database) answered and said
///     no (validation, RLS, out of stock, ...). Retrying the identical
///     request will fail the same way, so it is final.
bool isTransientFailure(Object error) {
  // Already classified by the repositories' error layer.
  if (error is AppError) return error.isConnectivity;
  if (error is TimeoutException) return true;
  if (error is PostgrestException) {
    final code = error.code ?? '';
    if (code.length == 3 && code.startsWith('5')) return true;
    return code == '401' ||
        code == 'PGRST301' ||
        code == 'PGRST302' ||
        code == 'PGRST303';
  }
  final text = error.toString().toLowerCase();
  return text.contains('socketexception') ||
      text.contains('clientexception') ||
      text.contains('handshakeexception') ||
      text.contains('failed host lookup') ||
      text.contains('connection closed') ||
      text.contains('connection reset') ||
      text.contains('connection refused') ||
      text.contains('connection timed out') ||
      text.contains('network is unreachable') ||
      text.contains('xmlhttprequest error');
}

/// A short, customer-safe description of [error] (never a raw stack/SDK dump).
String describeError(Object error) {
  if (error is AppError) return error.message;
  if (isTransientFailure(error)) {
    return 'Could not reach the server. Please check your connection.';
  }
  if (error is PostgrestException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
