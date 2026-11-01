import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/config/delivery_config.dart';
import 'package:melai_nuts/features/customer/widgets/downpayment_note.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';
import 'package:melai_nuts/data/models/cod_downpayment.dart';
import 'package:melai_nuts/data/models/delivery.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/models/staff_models.dart';

// The app's side of migration 20261101083000_cod_downpayment.sql.
void main() {
  Map<String, dynamic> orderRow(String status) => {
        'id': 'ORD-T-1',
        'created_at': '2026-11-01T02:00:00Z',
        'status': status,
        'branch_name': 'Branch',
        'is_delivery': true,
        'discount': 0,
        'delivery_fee': 50,
        'payment_method': 'Cash on Counter Pickup',
        'points_earned': 0,
      };
  final items = [
    {'product_name': 'Nut', 'variant_label': 'Regular', 'quantity': 1, 'unit_price': 100},
  ];

  group('the new order status', () {
    test('an order awaiting its downpayment can be read', () {
      final o = Order.fromRow(orderRow('awaitingDownpayment'), itemRows: items);
      expect(o.status, OrderStatus.awaitingDownpayment);
      expect(o.status.label, 'Awaiting Downpayment');
      expect(o.status.isActive, isTrue);
    });

    test('its timeline step can be read too', () {
      final steps = OrderTimelineStep.fromEventRows([
        {'status': 'awaitingDownpayment', 'created_at': '2026-11-01T02:00:00Z'},
      ]);
      expect(steps.single.label, 'Awaiting Downpayment');
    });
  });

  group('Order and its downpayment', () {
    test('the cash balance is the total less the downpayment', () {
      final o = Order.fromRow(orderRow('awaitingDownpayment'), itemRows: items, downpaymentRow: {
        'amount': 45,
        'status': 'pending',
        'expires_at': '2026-11-01T02:30:00Z',
      });
      expect(o.total, 150);
      expect(o.downpayment!.amount, 45);
      expect(o.cashBalance, 105);
    });

    test('without a downpayment the whole total is cash', () {
      final o = Order.fromRow(orderRow('pending'), itemRows: items);
      expect(o.downpayment, isNull);
      expect(o.cashBalance, 150);
    });
  });

  group('OrderDownpayment states', () {
    OrderDownpayment of(String status, {DateTime? expiresAt}) =>
        OrderDownpayment(amount: 45, status: status, expiresAt: expiresAt);

    test('what can still be paid', () {
      for (final s in ['pending', 'processing', 'failed']) {
        expect(of(s).isOpen, isTrue, reason: s);
      }
      for (final s in ['success', 'expired', 'refunded', 'forfeited']) {
        expect(of(s).isOpen, isFalse, reason: s);
      }
    });

    test('what counts as paid', () {
      expect(of('success').isPaid, isTrue);
      expect(of('refunded').isPaid, isTrue);
      expect(of('expired').isPaid, isFalse);
      expect(of('expired').isExpired, isTrue);
      expect(of('forfeited').isPaid, isTrue);
      expect(of('forfeited').isForfeited, isTrue);
    });

    test('the time limit', () {
      final limit = DateTime(2026, 11, 1, 10, 30);
      final d = of('pending', expiresAt: limit);
      expect(d.isPastLimit(limit.subtract(const Duration(seconds: 1))), isFalse);
      expect(d.isPastLimit(limit), isTrue);
      expect(of('pending').isPastLimit(limit), isFalse);
    });
  });

  group('CodDownpaymentQuote', () {
    test('required', () {
      final q = CodDownpaymentQuote.fromJson({
        'required': true,
        'amount': 45,
        'balance': 105,
        'expiry_minutes': 30,
        'percent': 30,
        'pickup_days': 2,
      });
      expect(q.percent, 30);
      expect(q.pickupDays, 2);
      expect(q.required, isTrue);
      expect(q.amount, 45);
      expect(q.balance, 105);
      expect(q.expiryMinutes, 30);
    });

    test('not required: the server leaves the time limit empty', () {
      final q = CodDownpaymentQuote.fromJson({'required': false, 'amount': 0, 'balance': 150, 'expiry_minutes': null});
      expect(q.required, isFalse);
      expect(q.expiryMinutes, isNull);
    });
  });

  group('the customer app is pickup only', () {
    test('delivery is hidden by default', () {
      expect(DeliveryConfig.customerDeliveryEnabled, isFalse);
    });
  });

  group('the downpayment note', () {
    Future<String> noteText(WidgetTester tester, Locale locale, DownpaymentNote note) async {
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: note),
      ));
      await tester.pumpAndSettle();
      return tester.widget<Text>(find.byType(Text)).data!;
    }

    testWidgets('English, with the real percent and days', (tester) async {
      final text = await noteText(tester, const Locale('en'),
          const DownpaymentNote(percent: 30, amount: 30, pickupDays: 2));
      expect(
        text,
        "Why a downpayment? To reserve your order, please pay 30% online now. The rest is paid in cash when you pick up. "
        "This helps us prepare your items and avoid unclaimed orders. If you don't pick up within 2 days, the downpayment is non-refundable.",
      );
    });

    testWidgets('Filipino, with the real percent and days', (tester) async {
      final text = await noteText(tester, const Locale('fil'),
          const DownpaymentNote(percent: 30, amount: 30, pickupDays: 2));
      expect(
        text,
        'Bakit may downpayment? Para ma-reserve ang order mo, magbayad ng 30% online ngayon. Ang natitira ay babayaran ng cash pagkuha mo. '
        'Nakakatulong ito para maihanda namin ang items mo at maiwasan ang hindi kinukuhang orders. '
        'Kung hindi makuha sa loob ng 2 araw, hindi na maibabalik ang downpayment.',
      );
    });

    testWidgets('other settings change the words, not just the sum', (tester) async {
      final text = await noteText(tester, const Locale('en'),
          const DownpaymentNote(percent: 25, amount: 25, pickupDays: 1));
      expect(text, contains('pay 25% online now'));
      expect(text, contains('within 1 day,'));
    });

    testWidgets('a fixed amount is shown in pesos', (tester) async {
      final text = await noteText(tester, const Locale('en'),
          const DownpaymentNote(amount: 100, pickupDays: 3));
      expect(text, contains('pay ₱100.00 online now'));
      expect(text, contains('within 3 days,'));
    });

    test('share labels', () {
      expect(DownpaymentNote.shareLabel(percent: 30, amount: 1), '30%');
      expect(DownpaymentNote.shareLabel(percent: 12.5, amount: 1), '12.5%');
      expect(DownpaymentNote.shareLabel(amount: 100), '₱100.00');
    });
  });

  group('what the rider collects', () {
    Map<String, dynamic> stop(Map<String, dynamic> extra) => {
          'id': 's-1',
          'order_id': 'ORD-T-1',
          'sequence_index': 0,
          'status': 'enRoute',
          'order_total': 150,
          'payment_method': 'cash',
          'payment_status': 'pending',
          ...extra,
        };

    test('the balance, not the order total', () {
      final s = DeliveryStop.fromJson(stop({'cash_due': 105, 'downpayment_paid': 45}));
      expect(s.needsCashCollection, isTrue);
      expect(s.amountDue, 105);
      expect(s.downpaymentPaid, 45);
    });

    test('an older server sends no balance: the order total, as before', () {
      expect(DeliveryStop.fromJson(stop({})).amountDue, 150);
    });
  });

  test('staff see the downpayment and the cash balance on an order', () {
    final o = StaffOrder.fromJson({
      'id': 'ORD-T-1',
      'created_at': '2026-11-01T02:00:00Z',
      'status': 'pending',
      'downpayment': {'amount': 45, 'status': 'success'},
      'payment': {'id': 'PAY-1', 'method': 'cash', 'status': 'pending', 'reference_number': 'x', 'amount': 105},
    });
    expect(o.downpaymentAmount, 45);
    expect(o.downpaymentStatus, 'success');
    expect(o.payment!.amount, 105);
  });

  test('a refund shows how much was the downpayment', () {
    final r = StaffRefund.fromJson({
      'id': 'REF-1',
      'order_id': 'ORD-T-1',
      'status': 'approved',
      'amount': 100,
      'payment_method': 'Cash on Delivery',
      'created_at': '2026-11-01T02:00:00Z',
      'downpayment_amount': 45,
    });
    expect(r.downpaymentAmount, 45);
  });
}
