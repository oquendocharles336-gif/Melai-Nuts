import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/email_verification_service.dart';
import 'package:melai_nuts/data/models/cod_downpayment.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/features/customer/widgets/first_order_payment_choice.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

// The app's side of migrations 20261118000000 (first order paid online, 50% or 100%) and
// 20261118010000 (e-mail codes). The rules themselves are enforced and tested on the server:
// supabase/tests/first_order_prepayment_test.sql, supabase/functions/email-verification.
void main() {
  group('first-order quote', () {
    test('a first order with both choices, read from the server', () {
      final q = FirstOrderQuote.fromJson({
        'first_order': true,
        'total': 150,
        'half_amount': 75,
        'half_balance': 75,
        'full_amount': 150,
        'expiry_minutes': 30,
        'pending_order_id': null,
        'online_payment_enabled': true,
      });
      expect(q.firstOrder, isTrue);
      expect([q.halfAmount, q.halfBalance, q.fullAmount], [75.0, 75.0, 150.0]);
      expect(q.pendingOrderId, isNull);
      expect(q.onlinePaymentEnabled, isTrue);
    });

    test('a returning customer gets the normal checkout', () {
      final q = FirstOrderQuote.fromJson({'first_order': false});
      expect(q.firstOrder, isFalse);
    });

    test('an unpaid first order is pointed to; an empty id is no order', () {
      expect(FirstOrderQuote.fromJson({'first_order': true, 'pending_order_id': 'ORD-9'}).pendingOrderId, 'ORD-9');
      expect(FirstOrderQuote.fromJson({'first_order': true, 'pending_order_id': '  '}).pendingOrderId, isNull);
    });

    test('the choices are sent as the server expects them', () {
      expect(FirstOrderChoice.half.wire, 'half');
      expect(FirstOrderChoice.full.wire, 'full');
    });
  });

  group('first-order online part on an order', () {
    test('kind and choice are read; the cash balance is what is left', () {
      final o = Order.fromRow({
        'id': 'ORD-F-1',
        'created_at': '2026-11-18T02:00:00Z',
        'status': 'awaitingDownpayment',
        'branch_name': 'Branch',
        'is_delivery': false,
        'discount': 0,
        'delivery_fee': 0,
        'payment_method': 'Online Payment (GCash, QR Ph, Card)',
        'points_earned': 0,
      }, itemRows: [
        {'product_name': 'Nut', 'variant_label': 'Regular', 'quantity': 2, 'unit_price': 100},
      ], downpaymentRow: {
        'amount': 100,
        'status': 'pending',
        'expires_at': '2026-11-18T02:30:00Z',
        'percent': 50,
        'pickup_days': null,
        'kind': 'first_order',
        'choice': 'half',
      });
      expect(o.downpayment!.isFirstOrder, isTrue);
      expect(o.downpayment!.choice, 'half');
      expect(o.cashBalance, 100);
    });

    test('an older row without kind is a pickup downpayment', () {
      final d = OrderDownpayment.fromRow({'amount': 30, 'status': 'success'});
      expect(d.isFirstOrder, isFalse);
      expect(d.kind, 'cod');
    });
  });

  testWidgets('the choice shows the exact amounts and reports the tap', (tester) async {
    FirstOrderChoice? picked;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: FirstOrderPaymentChoice(
            quote: FirstOrderQuote.fromJson({
              'first_order': true, 'total': 220, 'half_amount': 110, 'half_balance': 110,
              'full_amount': 220, 'expiry_minutes': 30, 'online_payment_enabled': true,
            }),
            selected: null,
            isDelivery: false,
            onChanged: (c) => picked = c,
          ),
        ),
      ),
    ));
    expect(find.text('Pay 50% now'), findsOneWidget);
    expect(find.text('Pay 100% now'), findsOneWidget);
    expect(find.textContaining('₱110.00 online now, then ₱110.00 in cash'), findsOneWidget);
    expect(find.textContaining('₱220.00 online now'), findsOneWidget);
    await tester.tap(find.text('Pay 100% now'));
    expect(picked, FirstOrderChoice.full);
  });

  group('e-mail code answers become clear text', () {
    String m(String? code, int status, {bool verifying = true}) =>
        EmailVerificationService.messageFor(code, status, verifying: verifying, retryAfter: 42);

    test('captcha problems ask for the check again', () {
      expect(m('captcha_required', 428), contains('security check'));
      expect(m('captcha_invalid', 400), contains('security check'));
      expect(const EmailVerificationException('x', code: 'captcha_invalid').needsCaptcha, isTrue);
      expect(const EmailVerificationException('x', code: 'wrong_code').needsCaptcha, isFalse);
    });

    test('code problems', () {
      expect(m('wrong_code', 400), contains('incorrect'));
      expect(m('code_expired', 400), contains('expired'));
      expect(m('code_used', 400), contains('already used'));
      expect(m('too_many_attempts', 429), contains('Too many wrong codes'));
      expect(m('cooldown', 429, verifying: false), contains('42 seconds'));
    });

    test('unknown answers never show server text', () {
      expect(m(null, 500), 'We could not verify the code. Please try again.');
      expect(m(null, 500, verifying: false), 'We could not send the code. Please try again.');
    });
  });
}
