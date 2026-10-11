/// Which payment methods customers may use right now.
///
/// Online payment (HitPay: GCash, Maya, card) is temporarily DISABLED. The
/// code behind it is kept as it is — only the option is switched off:
///  * checkout shows it greyed out as "Temporarily unavailable" and cannot
///    place an online order;
///  * "Pay now" on an older pending online order does not open HitPay;
///  * the database refuses new online orders while
///    `payment_settings.online_payment_enabled` is false (migration
///    20261017000000_online_payment_switch.sql), so older app builds cannot
///    use it either, and the hitpay-create-payment Edge Function refuses too.
///
/// To turn it back on: set the database switch to true AND build the app with
/// `--dart-define=ONLINE_PAYMENT_ENABLED=true` (or change the default below).
class PaymentConfig {
  PaymentConfig._();

  static const bool onlinePaymentEnabled = bool.fromEnvironment('ONLINE_PAYMENT_ENABLED', defaultValue: true);

  static const String onlinePaymentDisabledMessage =
      'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.';
}
