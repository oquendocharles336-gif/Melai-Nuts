import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/config/payment_config.dart';
import '../../core/services/supabase_service.dart';

/// The owner's online-payment switch and the text customers see while it is
/// off, from `payment_settings` (readable by everyone; only the database
/// owner can change it). See [PaymentConfig].
class PaymentSettings {
  /// `payment_settings.online_payment_enabled`.
  final bool onlinePaymentEnabled;

  /// `payment_settings.online_payment_disabled_message`; null when empty.
  final String? disabledMessage;

  const PaymentSettings({required this.onlinePaymentEnabled, this.disabledMessage});

  /// Nothing could be read: online payment stays off.
  static const PaymentSettings unknown = PaymentSettings(onlinePaymentEnabled: false);

  factory PaymentSettings.fromRow(Map<String, dynamic>? row) {
    final raw = (row?['online_payment_disabled_message'] as String?)?.trim();
    return PaymentSettings(
      onlinePaymentEnabled: row?['online_payment_enabled'] == true,
      disabledMessage: (raw == null || raw.isEmpty) ? null : raw,
    );
  }

  /// Online payment is offered only when the build switch AND the database
  /// switch are both on.
  bool get onlineAllowed => PaymentConfig.onlinePaymentEnabled && onlinePaymentEnabled;

  /// The text to show while online payment is not offered.
  String get unavailableMessage => disabledMessage ?? PaymentConfig.onlinePaymentDisabledMessage;
}

class PaymentSettingsRepository {
  PaymentSettingsRepository._();
  static final PaymentSettingsRepository instance = PaymentSettingsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<PaymentSettings> fetch() async {
    final row = await _client
        .from('payment_settings')
        .select('online_payment_enabled, online_payment_disabled_message')
        .eq('id', 'default')
        .maybeSingle();
    return PaymentSettings.fromRow(row);
  }
}
