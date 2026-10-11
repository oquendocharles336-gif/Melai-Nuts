import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/config/payment_config.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/repositories/payments_repository.dart';

void main() {
  test('online payment is disabled for customers by default', () {
    expect(PaymentConfig.onlinePaymentEnabled, isFalse);
    expect(PaymentConfig.onlinePaymentDisabledMessage, contains('temporarily unavailable'));
  });

  test('the HitPay payment page is never opened while online payment is disabled', () async {
    await expectLater(
      PaymentsRepository.instance.startHitpayCheckout('ORD-1'),
      throwsA(isA<AppError>().having((e) => e.message, 'message', PaymentConfig.onlinePaymentDisabledMessage)),
    );
  });
}
