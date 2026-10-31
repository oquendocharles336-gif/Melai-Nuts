/// Which payment methods customers may use right now.
///
/// Customers can pay online through HitPay's hosted checkout (GCash, QR Ph,
/// card), by Cash on Delivery, or by Cash on Counter Pickup; in-store POS
/// sales (cash, in-store GCash / card reference) are not affected.
///
/// Online payment is offered only when BOTH switches are on:
///  * this build switch — `--dart-define=ONLINE_PAYMENT_ENABLED=...`
///    (default true; env/firebase.example.json sets it to "true"), and
///  * the database switch `payment_settings.online_payment_enabled`
///    (migrations 20261017000000 / 20261031034858, read by
///    PaymentSettingsRepository).
/// While either is off, checkout hides the option and shows the database's
/// `online_payment_disabled_message`; the database refuses online orders and
/// the hitpay-create-payment Edge Function refuses too. Build with
/// `ONLINE_PAYMENT_ENABLED=false` to ship a cash-only app.
class PaymentConfig {
  PaymentConfig._();

  static const bool onlinePaymentEnabled = bool.fromEnvironment('ONLINE_PAYMENT_ENABLED', defaultValue: true);

  /// Shown only when the database message cannot be read (e.g. no connection);
  /// the normal text comes from `payment_settings.online_payment_disabled_message`.
  static const String onlinePaymentDisabledMessage =
      'Online payment is temporarily unavailable. Please choose Cash on Delivery or Cash on Counter Pickup.';

  /// The `orders.payment_method` labels paid through HitPay (the current
  /// checkout label and the older ones the database still accepts).
  static const Set<String> onlinePaymentLabels = {
    'Online Payment (GCash, QR Ph, Card)',
    'Online Payment (GCash, Maya, Card)',
    'GCash E-Wallet',
    'Maya / Credit Card',
  };

  static bool isOnlinePayment(String paymentMethod) => onlinePaymentLabels.contains(paymentMethod);
}
