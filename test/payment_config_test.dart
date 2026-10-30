import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/config/payment_config.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/repositories/payment_settings_repository.dart';
import 'package:melai_nuts/data/repositories/payments_repository.dart';

void main() {
  test('online payment (HitPay) is enabled in the build by default', () {
    expect(PaymentConfig.onlinePaymentEnabled, isTrue);
    expect(PaymentConfig.onlinePaymentDisabledMessage, contains('temporarily unavailable'));
  });

  test('online payment labels are recognised, cash labels are not', () {
    expect(PaymentConfig.isOnlinePayment('Online Payment (GCash, Maya, Card)'), isTrue);
    expect(PaymentConfig.isOnlinePayment('GCash E-Wallet'), isTrue);
    expect(PaymentConfig.isOnlinePayment('Maya / Credit Card'), isTrue);
    expect(PaymentConfig.isOnlinePayment('Cash on Delivery'), isFalse);
    expect(PaymentConfig.isOnlinePayment('Cash on Counter Pickup'), isFalse);
  });

  test('the HitPay payment page is never opened in a build where online payment is disabled', () async {
    if (PaymentConfig.onlinePaymentEnabled) return; // only meaningful with ONLINE_PAYMENT_ENABLED=false
    await expectLater(
      PaymentsRepository.instance.startHitpayCheckout('ORD-TEST-1'),
      throwsA(isA<AppError>().having((e) => e.message, 'message', PaymentConfig.onlinePaymentDisabledMessage)),
    );
  });

  group('PaymentSettings (payment_settings row)', () {
    test('the database message is used while online payment is off', () {
      final s = PaymentSettings.fromRow({
        'online_payment_enabled': false,
        'online_payment_disabled_message': '  Paying online is paused.  ',
      });
      expect(s.onlinePaymentEnabled, isFalse);
      expect(s.onlineAllowed, isFalse);
      expect(s.unavailableMessage, 'Paying online is paused.');
    });

    test('an empty or missing message falls back to the built-in text', () {
      expect(PaymentSettings.fromRow({'online_payment_enabled': false, 'online_payment_disabled_message': ' '}).unavailableMessage,
          PaymentConfig.onlinePaymentDisabledMessage);
      expect(PaymentSettings.fromRow(null).unavailableMessage, PaymentConfig.onlinePaymentDisabledMessage);
    });

    test('a missing row or an unreadable switch keeps online payment off', () {
      expect(PaymentSettings.fromRow(null).onlineAllowed, isFalse);
      expect(PaymentSettings.fromRow({'online_payment_enabled': 'yes'}).onlineAllowed, isFalse);
      expect(PaymentSettings.unknown.onlineAllowed, isFalse);
    });

    test('online payment is offered when the database switch and the build switch are on', () {
      final s = PaymentSettings.fromRow({'online_payment_enabled': true});
      expect(s.onlinePaymentEnabled, isTrue);
      expect(s.onlineAllowed, PaymentConfig.onlinePaymentEnabled); // the build switch still has the last word
    });
  });
}
