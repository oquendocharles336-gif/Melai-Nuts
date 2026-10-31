import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/payment.dart';

Map<String, dynamic> _row(String method) => {
      'id': 'p1',
      'order_id': 'ORD-1',
      'created_at': '2026-10-31T04:15:07Z',
      'method': method,
      'status': 'success',
      'amount': 1050,
      'reference_number': 'ORD-1',
    };

void main() {
  test('every method code the database allows is read as itself', () {
    const codes = [
      'gcash', 'maya', 'card', 'cash', 'qrph', 'grabpay', 'shopeepay', 'spaylater', 'billease',
      'wechat', 'unionbank', 'instapay', 'pesonet', 'bayad', 'ecpay', 'palawan', 'online',
    ];
    for (final code in codes) {
      expect(PaymentTransaction.fromRow(_row(code)).method.name, code);
    }
  });

  test('a QR Ph payment is labelled QR Ph, not card', () {
    expect(PaymentTransaction.fromRow(_row('qrph')).method.label, 'QR Ph');
  });

  test('a code this build does not know still loads, as an online payment', () {
    expect(PaymentTransaction.fromRow(_row('brand_new_wallet')).method, PaymentMethod.online);
  });
}
