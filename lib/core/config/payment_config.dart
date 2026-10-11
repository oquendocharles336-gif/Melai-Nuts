/// Which payment methods customers may use right now.
///
/// OWNER DECISION: online payment (HitPay: GCash, Maya, card) is UNAVAILABLE.
/// Customers pay by Cash on Delivery or Cash on Counter Pickup; in-store POS
/// sales (cash, in-store GCash / card reference) are not affected.
///
/// Online payment is offered only when BOTH switches are on:
///  * this build switch — `--dart-define=ONLINE_PAYMENT_ENABLED=true`
///    (default false; env/firebase.example.json sets it to "false"), and
///  * the database switch `payment_settings.online_payment_enabled`
///    (migration 20261017000000, read by PaymentSettingsRepository).
/// While either is off, checkout hides the option and shows the database's
/// `online_payment_disabled_message`; the database refuses online orders from
/// older app builds and the hitpay-create-payment Edge Function refuses too.
/// The HitPay code stays dormant and intact so it can be re-enabled later.
class PaymentConfig {
  PaymentConfig._();

  static const bool onlinePaymentEnabled = bool.fromEnvironment('ONLINE_PAYMENT_ENABLED', defaultValue: false);

  /// Shown only when the database message cannot be read (e.g. no connection);
  /// the normal text comes from `payment_settings.online_payment_disabled_message`.
  static const String onlinePaymentDisabledMessage =
      'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.';
}
