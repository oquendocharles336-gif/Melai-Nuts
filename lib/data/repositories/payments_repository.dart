import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/config/payment_config.dart';
import '../../core/services/supabase_service.dart';
import '../../core/services/supabase_token.dart';
import '../../core/utils/app_error.dart';
import '../models/payment.dart';

/// READ-ONLY access to the customer's payment records in Supabase.
///
/// A payment row is created by the database itself, inside the same
/// transaction as the order (`place_order`), always as `pending`. The
/// customer roles have no INSERT/UPDATE/DELETE privilege on `payments`, so
/// this app can neither create a payment record nor mark one as paid — a
/// modified client cannot either. A payment only moves past `pending` when a
/// trusted server-side path does it (staff confirming a cash/e-wallet
/// payment, or a payment-gateway webhook running with its own credentials).
///
/// There is deliberately no `recordPayment`/`markStatus` here. Do not add
/// client-side writes: the database will reject them, and they would be the
/// attack surface if it did not. [startHitpayCheckout] writes nothing from
/// the app either: it asks the `hitpay-create-payment` Edge Function, which
/// reads the amount from the database, for the HitPay checkout link.
class PaymentsRepository {
  PaymentsRepository._();
  static final PaymentsRepository instance = PaymentsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<List<PaymentTransaction>> fetchAll(String firebaseUid) async {
    final raw = await _client
        .from('payments')
        .select()
        .eq('firebase_uid', firebaseUid)
        .order('created_at', ascending: false)
        // Newest payments only: each order row also embeds its own payments,
        // so older orders opened from the paged history still show theirs.
        .limit(200);
    return List<Map<String, dynamic>>.from(raw).map(PaymentTransaction.fromRow).toList();
  }

  /// Live view of this customer's payments (status changes made by staff or
  /// the payment provider webhook). Each event is the full current list.
  Stream<List<PaymentTransaction>> watchAll(String firebaseUid) {
    return _client
        .from('payments')
        .stream(primaryKey: ['id'])
        .eq('firebase_uid', firebaseUid)
        .order('created_at', ascending: false)
        .map((rows) => rows.map(PaymentTransaction.fromRow).toList())
        .transform(StreamTransformer<List<PaymentTransaction>, List<PaymentTransaction>>.fromHandlers(
          handleError: (error, stackTrace, sink) => sink.addError(AppErrors.from(error), stackTrace),
        ));
  }

  /// The single payment for [orderId] (one per order is enforced by a unique
  /// index), or null if there is none / it is not yours.
  Future<PaymentTransaction?> fetchForOrder(String orderId) async {
    final row = await _client.from('payments').select().eq('order_id', orderId).maybeSingle();
    return row == null ? null : PaymentTransaction.fromRow(row);
  }

  /// Asks the `hitpay-create-payment` Edge Function for the HitPay hosted
  /// checkout URL of [orderId] (an existing link is reused while the payment
  /// is still open). The Firebase ID token is attached explicitly because the
  /// client authenticates through [SupabaseToken], not Supabase Auth.
  /// Throws an [AppError] with a customer-safe message on failure.
  Future<String> startHitpayCheckout(String orderId) async {
    // Online payment is temporarily disabled (see PaymentConfig): never open
    // the HitPay page, even for an older pending online order.
    if (!PaymentConfig.onlinePaymentEnabled) {
      throw const AppError(AppErrorKind.paymentFailed, PaymentConfig.onlinePaymentDisabledMessage);
    }
    final token = await SupabaseToken.fetch();
    if (token == null) {
      throw const AppError(AppErrorKind.authExpired, 'Please sign in again to continue with your payment.');
    }
    try {
      final response = await _client.functions.invoke(
        'hitpay-create-payment',
        headers: {'Authorization': 'Bearer $token'},
        body: {'order_id': orderId},
      ).timeout(AppErrors.rpcTimeout);
      final data = response.data;
      final url = data is Map ? data['checkout_url'] : null;
      if (url is String && url.isNotEmpty) return url;
    } on FunctionException catch (e) {
      final details = e.details;
      final message = details is Map && details['error'] is String ? details['error'] as String : null;
      throw AppError(
        AppErrorKind.paymentFailed,
        message ?? 'We could not open the payment page. Please try again.',
      );
    } catch (e) {
      throw AppErrors.from(e, scope: ErrorScope.order);
    }
    throw const AppError(
      AppErrorKind.paymentFailed,
      'We could not open the payment page. Please try again.',
    );
  }
}
