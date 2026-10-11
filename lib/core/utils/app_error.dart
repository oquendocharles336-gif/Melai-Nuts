import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What went wrong, in customer terms. Screens can branch on this (e.g. to
/// refresh stock after [insufficientStock]) without ever looking at the raw
/// backend error.
enum AppErrorKind {
  noInternet,
  timeout,
  authExpired,
  permissionDenied,
  notFound,
  invalidData,
  insufficientStock,
  productUnavailable,
  branchUnavailable,
  invalidVoucher,
  insufficientPoints,
  paymentFailed,
  orderFailed,
  refundFailed,
  database,

  /// The on-device database (SQLite) failed. Never about the person's data
  /// on the server.
  localStorage,

  /// Staff access states (see `StaffSessionStore`): each has a fixed,
  /// person-readable message and never any backend detail.
  staffNotProvisioned,
  accountInactive,
  accountSuspended,
  invalidRole,
  invalidBranch,
  accessDenied,
  unknown,
}

/// Which operation was running. Only used to pick wording ("we couldn't find
/// that order" vs "that address no longer exists") and the fallback message.
enum ErrorScope { general, order, refund, address, profile, cart, catalog }

/// An error that is always safe to show to a customer: [message] never
/// contains SQL, stack traces, Firebase/Supabase internals or secrets.
/// `toString()` returns [message], so even code that still does
/// `'...${e.toString()}'` cannot leak anything once the error came from here.
class AppError implements Exception {
  final AppErrorKind kind;
  final String message;

  const AppError(this.kind, this.message);

  /// The request may or may not have reached the server.
  bool get isConnectivity => kind == AppErrorKind.noInternet || kind == AppErrorKind.timeout;

  /// The cart no longer matches real stock/availability.
  bool get isStockRelated =>
      kind == AppErrorKind.insufficientStock || kind == AppErrorKind.productUnavailable;

  @override
  String toString() => message;
}

/// Turns anything a backend call can throw into an [AppError].
class AppErrors {
  AppErrors._();

  static const Duration queryTimeout = Duration(seconds: 20);
  static const Duration rpcTimeout = Duration(seconds: 30);

  /// Runs [action] with a timeout and converts any failure to an [AppError].
  ///
  /// Note: a client-side timeout does not cancel a request that already
  /// reached the server. That is why order placement uses an idempotency key —
  /// a retry after a timeout returns the same order instead of a duplicate.
  static Future<T> guard<T>(
    Future<T> Function() action, {
    ErrorScope scope = ErrorScope.general,
    Duration timeout = queryTimeout,
  }) async {
    try {
      return await action().timeout(timeout);
    } catch (e, st) {
      Error.throwWithStackTrace(from(e, scope: scope), st);
    }
  }

  /// Shows a customer-friendly snackbar for [error]. Callers must check
  /// `mounted` first.
  static void showSnack(
    BuildContext context,
    Object error, {
    ErrorScope scope = ErrorScope.general,
    Duration duration = const Duration(seconds: 5),
  }) {
    final message = from(error, scope: scope).message;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: duration));
  }

  static AppError from(Object error, {ErrorScope scope = ErrorScope.general}) {
    if (error is AppError) return error;
    if (kDebugMode) {
      // Raw details go to the debug console only — never to the UI.
      debugPrint('[AppErrors:${scope.name}] ${error.runtimeType}: $error');
    }
    return _map(error, scope);
  }

  // ---------------------------------------------------------------------
  // Mapping
  // ---------------------------------------------------------------------

  static AppError _map(Object error, ErrorScope scope) {
    if (error is TimeoutException) return _timeout(scope);
    if (error is PostgrestException) return _fromPostgrest(error, scope);
    if (error is AuthException) return _fromAuthException(error);

    // On-device database failures (sqflite / sqlite). Checked before the
    // generic text rules because their messages can contain SQL.
    final lowered = error.toString().toLowerCase();
    if (_hasAny(lowered, const ['databaseexception', 'sqliteexception', 'sqflite', 'sqlite_', 'no such table'])) {
      return localStorageError();
    }

    // String checks (not runtimeType) so this keeps working in minified web
    // builds and without importing dart:io.
    final text = error.toString().toLowerCase();
    if (_isNetworkFailure(text)) return _noInternet(scope);
    if (text.startsWith('[firebase_auth/')) return _fromFirebaseAuth(text);
    if (error is FormatException || error is TypeError) {
      return const AppError(
        AppErrorKind.invalidData,
        'We received some unexpected data. Please try again.',
      );
    }

    final byMessage = _fromMessage(text, scope);
    if (byMessage != null) return byMessage;

    // A plain `throw Exception('...')` from our own code carries a message
    // written for the customer. Pass it through only if it looks clean.
    if (text.startsWith('exception: ')) {
      final raw = error.toString().substring('Exception: '.length).trim();
      if (_isSafeToShow(raw)) return AppError(AppErrorKind.unknown, raw);
    }
    return _generic(scope);
  }

  static AppError _fromPostgrest(PostgrestException e, ErrorScope scope) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();

    if (code == 'PGRST301' || code == 'PGRST302' || code == '401' || msg.contains('jwt')) {
      return _authExpired();
    }
    if (code == '42501' ||
        code == '403' ||
        msg.contains('row-level security') ||
        msg.contains('permission denied')) {
      return _permissionDenied();
    }
    if (code == 'PGRST116' || code == '404') return _notFound(scope);
    if (code == '57014') return _timeout(scope);

    // Programming/schema/infrastructure problems: never the customer's fault
    // and never something to describe to them.
    if (code.startsWith('42') ||
        code.startsWith('PGRST') ||
        code.startsWith('08') ||
        code.startsWith('53') ||
        code.startsWith('57P') ||
        code.startsWith('XX') ||
        code == '40001' ||
        code == '40P01') {
      return _database(scope);
    }

    // Business rules raised by the database functions (place_order,
    // request_refund, ...): stock, voucher, points, branch, etc.
    final byMessage = _fromMessage(msg, scope);
    if (byMessage != null) return byMessage;

    if (code == '23503') return _notFound(scope);
    if (code == '23505') {
      return const AppError(AppErrorKind.invalidData, 'That has already been saved.');
    }
    if (code.startsWith('22') || code == '23502' || code == '23514') {
      return const AppError(
        AppErrorKind.invalidData,
        'Some of the details look invalid. Please check them and try again.',
      );
    }
    if (code == 'P0001' && _isSafeToShow(e.message)) {
      return AppError(AppErrorKind.unknown, e.message.trim());
    }
    return _database(scope);
  }

  static AppError _fromAuthException(AuthException e) {
    final msg = e.message.toLowerCase();
    if (_isNetworkFailure(msg)) return _noInternet(ErrorScope.general);
    if (msg.contains('expired') || msg.contains('jwt') || msg.contains('not authenticated')) {
      return _authExpired();
    }
    if (msg.contains('rate limit') || msg.contains('too many')) {
      return const AppError(AppErrorKind.unknown, 'Too many attempts. Please wait a moment and try again.');
    }
    return _authExpired();
  }

  static AppError _fromFirebaseAuth(String text) {
    // Format: "[firebase_auth/some-code] message"
    final end = text.indexOf(']');
    final code = end > 15 ? text.substring(15, end) : '';
    switch (code) {
      case 'network-request-failed':
        return _noInternet(ErrorScope.general);
      case 'too-many-requests':
        return const AppError(AppErrorKind.unknown, 'Too many attempts. Please wait a moment and try again.');
      case 'user-token-expired':
      case 'invalid-user-token':
      case 'requires-recent-login':
      case 'user-disabled':
      case 'user-not-found':
        return _authExpired();
      default:
        return const AppError(AppErrorKind.unknown, 'We couldn\'t verify your account. Please sign in again.');
    }
  }

  /// Classifies business-rule text. Returns null when nothing matches.
  static AppError? _fromMessage(String t, ErrorScope scope) {
    if (_hasAny(t, const ['jwt expired', 'token expired', 'not authenticated', 'not signed in', 'session expired'])) {
      return _authExpired();
    }
    if (_hasAny(t, const ['permission denied', 'not authorized', 'not allowed', 'forbidden', 'does not belong to'])) {
      return _permissionDenied();
    }
    if (_hasAny(t, const ['voucher', 'promo code', 'coupon'])) {
      return const AppError(
        AppErrorKind.invalidVoucher,
        'That voucher can\'t be used. It may be expired, already used, or not valid for this order.',
      );
    }
    if (RegExp(r'\b(points?|loyalty)\b').hasMatch(t) &&
        _hasAny(t, const ['insufficient', 'not enough', 'exceed'])) {
      return const AppError(
        AppErrorKind.insufficientPoints,
        'You don\'t have enough loyalty points for this redemption.',
      );
    }
    if (_hasAny(t, const ['stock', 'inventory', 'sold out'])) {
      return const AppError(
        AppErrorKind.insufficientStock,
        'Some items in your cart don\'t have enough stock right now. Please lower the quantity or remove them.',
      );
    }
    if (t.contains('branch') &&
        _hasAny(t, const [
          'closed', 'unavailable', 'not available', 'inactive',
          'not accepting', 'does not deliver', 'not offer', 'no longer',
        ])) {
      return const AppError(
        AppErrorKind.branchUnavailable,
        'This branch can\'t take your order right now. Please choose another branch or try again later.',
      );
    }
    if (t.contains('no longer available') ||
        (_hasAny(t, const ['unavailable', 'not available', 'inactive', 'discontinued', 'taken off']) &&
            _hasAny(t, const ['product', 'item', 'variant', 'sku']))) {
      return const AppError(
        AppErrorKind.productUnavailable,
        'One or more items are no longer available. Please remove them from your cart.',
      );
    }
    if (t.contains('payment')) {
      return const AppError(
        AppErrorKind.paymentFailed,
        'Your payment didn\'t go through. Please check your payment method and try again.',
      );
    }
    if (t.contains('refund')) {
      return const AppError(
        AppErrorKind.refundFailed,
        'We couldn\'t process your refund request. Please try again or contact the branch.',
      );
    }
    if (t.contains('cart') && t.contains('empty')) {
      return const AppError(AppErrorKind.invalidData, 'Your cart is empty.');
    }
    if (t.contains('phone')) {
      return const AppError(AppErrorKind.invalidData, 'Please add a valid contact phone number and try again.');
    }
    if (t.contains('address')) {
      return const AppError(AppErrorKind.invalidData, 'Please enter a complete delivery address and try again.');
    }
    if (_hasAny(t, const ['not found', 'does not exist', 'no longer exists', 'no rows'])) {
      return _notFound(scope);
    }
    if (_hasAny(t, const ['invalid', 'required', 'must be', 'too long', 'too short'])) {
      return const AppError(
        AppErrorKind.invalidData,
        'Some of the details look invalid. Please check them and try again.',
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Fixed, customer-friendly messages
  // ---------------------------------------------------------------------

  static AppError _noInternet(ErrorScope scope) {
    if (scope == ErrorScope.order) {
      return const AppError(
        AppErrorKind.noInternet,
        'We couldn\'t confirm your order because the connection dropped. If it did go through, '
        'tapping Place Order again won\'t create a duplicate. Please check your connection and try again.',
      );
    }
    return const AppError(
      AppErrorKind.noInternet,
      'You\'re offline. Please check your internet connection and try again.',
    );
  }

  static AppError _timeout(ErrorScope scope) {
    if (scope == ErrorScope.order) {
      return const AppError(
        AppErrorKind.timeout,
        'This is taking longer than expected, so we couldn\'t confirm your order. If it did go through, '
        'tapping Place Order again won\'t create a duplicate. Please try again.',
      );
    }
    return const AppError(
      AppErrorKind.timeout,
      'This is taking longer than expected. Please try again.',
    );
  }

  /// The on-device database could not be read or written.
  static AppError localStorageError() => const AppError(
        AppErrorKind.localStorage,
        'We couldn\'t read or save information on this device. Please try again.',
      );

  static AppError staffNotProvisioned() => const AppError(
        AppErrorKind.staffNotProvisioned,
        'Your staff account has not been set up yet. Please contact your administrator.',
      );

  static AppError accountInactive() => const AppError(
        AppErrorKind.accountInactive,
        'This staff account has been deactivated. Please contact your administrator.',
      );

  static AppError accountSuspended() => const AppError(
        AppErrorKind.accountSuspended,
        'This staff account has been suspended. Please contact your administrator.',
      );

  static AppError invalidRole() => const AppError(
        AppErrorKind.invalidRole,
        'This account has a role the app does not recognise. Please contact your administrator.',
      );

  static AppError invalidBranch() => const AppError(
        AppErrorKind.invalidBranch,
        'Your account is not assigned to a valid branch. Please contact your administrator.',
      );

  static AppError accessDenied() => const AppError(
        AppErrorKind.accessDenied,
        'You don\'t have access to this area.',
      );

  static AppError _authExpired() => const AppError(
        AppErrorKind.authExpired,
        'Your session has expired. Please sign in again.',
      );

  static AppError _permissionDenied() => const AppError(
        AppErrorKind.permissionDenied,
        'You don\'t have permission to do that.',
      );

  static AppError _notFound(ErrorScope scope) {
    switch (scope) {
      case ErrorScope.order:
        return const AppError(AppErrorKind.notFound, 'We couldn\'t find that order.');
      case ErrorScope.refund:
        return const AppError(AppErrorKind.notFound, 'We couldn\'t find that refund request.');
      case ErrorScope.address:
        return const AppError(AppErrorKind.notFound, 'That address no longer exists.');
      case ErrorScope.cart:
        return const AppError(AppErrorKind.notFound, 'We couldn\'t find your cart. Please reopen it and try again.');
      case ErrorScope.profile:
        return const AppError(AppErrorKind.notFound, 'We couldn\'t find your profile.');
      case ErrorScope.catalog:
      case ErrorScope.general:
        return const AppError(AppErrorKind.notFound, 'We couldn\'t find what you were looking for.');
    }
  }

  static AppError _database(ErrorScope scope) => _generic(scope, kind: AppErrorKind.database);

  static AppError _generic(ErrorScope scope, {AppErrorKind kind = AppErrorKind.unknown}) {
    switch (scope) {
      case ErrorScope.order:
        return const AppError(AppErrorKind.orderFailed, 'We couldn\'t place your order. Please try again.');
      case ErrorScope.refund:
        return const AppError(
          AppErrorKind.refundFailed,
          'We couldn\'t submit your refund request. Please try again or contact the branch.',
        );
      case ErrorScope.address:
        return AppError(kind, 'We couldn\'t save your address. Please try again.');
      default:
        return AppError(kind, 'Something went wrong on our end. Please try again in a moment.');
    }
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  static bool _hasAny(String text, List<String> needles) {
    for (final n in needles) {
      if (text.contains(n)) return true;
    }
    return false;
  }

  static bool _isNetworkFailure(String t) => _hasAny(t, const [
        'socketexception',
        'clientexception',
        'handshakeexception',
        'failed host lookup',
        'connection closed',
        'connection reset',
        'connection refused',
        'connection terminated',
        'network is unreachable',
        'xmlhttprequest error',
        'no address associated',
      ]);

  static const List<String> _blockedFragments = [
    'sql', 'postgres', 'pgrst', 'supabase', 'firebase', 'gotrue', 'realtime',
    'relation', 'column', 'constraint', 'violates', 'syntax', 'stack', 'trace',
    '.dart', 'null check', 'instance of', 'jwt', 'token', 'secret', 'apikey',
    'api key', 'policy', 'function', 'schema', 'http', 'socket', 'exception',
    'error:', 'rpc', 'public.',
  ];

  /// True when [raw] reads like a sentence written for a person rather than a
  /// technical message (no identifiers, ids, internals or markup).
  static bool _isSafeToShow(String raw) {
    if (raw.length < 4 || raw.length > 160) return false;
    final lower = raw.toLowerCase();
    for (final fragment in _blockedFragments) {
      if (lower.contains(fragment)) return false;
    }
    if (RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-').hasMatch(lower)) return false; // uuid
    if (RegExp(r'\b[a-z0-9]+_[a-z0-9_]+\b').hasMatch(lower)) return false; // snake_case ids
    if (RegExp(r'[{}<>\[\]\\]').hasMatch(raw)) return false;
    return true;
  }
}
