/// Whether customers are offered delivery.
///
/// Melai Nuts is store pickup only, so the customer app hides delivery (Melai Van,
/// Cash on Delivery, addresses and map pins). The delivery and driver code stays:
/// build with `--dart-define=CUSTOMER_DELIVERY_ENABLED=true` to bring it back. Past
/// delivery orders still show their details, and the server keeps refusing delivery
/// at any branch that has it switched off.
class DeliveryConfig {
  DeliveryConfig._();

  static const bool customerDeliveryEnabled = bool.fromEnvironment('CUSTOMER_DELIVERY_ENABLED', defaultValue: false);
}
