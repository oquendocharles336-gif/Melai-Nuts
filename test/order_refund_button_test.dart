import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/routes.dart';
import 'package:melai_nuts/core/services/customer_data_store.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/models/refund.dart';
import 'package:melai_nuts/data/repositories/refunds_repository.dart';
import 'package:melai_nuts/features/customer/screens/order_details_screen.dart';

const _item = OrderItem(productName: 'Nut', variantLabel: 'Regular', quantity: 1, unitPrice: 100);

Order _order(OrderStatus status, {DateTime? pickedUp}) => Order(
      id: 'ORD-T1',
      date: pickedUp ?? DateTime.now(),
      timeline: [
        if (pickedUp != null)
          OrderTimelineStep(label: 'Completed', description: '', time: '', status: OrderStatus.completed, at: pickedUp),
      ],
      status: status,
      branch: 'Branch',
      isDelivery: false,
      items: const [_item],
      deliveryFee: 0,
      paymentMethod: 'Cash on Counter Pickup',
      pointsEarned: 0,
    );

RefundRequest _refund(RefundStatus status, {String orderId = 'ORD-T1'}) => RefundRequest(
      id: 'RF-${status.name}-$orderId',
      orderId: orderId,
      requestedDate: DateTime(2026, 11, 1),
      status: status,
      reason: 'Damaged',
      items: const [_item],
      amount: 100,
      paymentMethod: 'Cash on Counter Pickup',
    );

void main() {
  final store = CustomerDataStore.instance;
  RouteSettings? opened;

  int? refundDays;

  setUp(() {
    opened = null;
    refundDays = null;
    store.refunds.clear();
    RefundsRepository.refundDaysOverride = () async => refundDays;
  });
  tearDown(() {
    store.refunds.clear();
    RefundsRepository.refundDaysOverride = null;
  });

  Future<void> show(WidgetTester tester, Order order) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: OrderDetailsScreen(order: order),
      onGenerateRoute: (settings) {
        opened = settings;
        return MaterialPageRoute(settings: settings, builder: (_) => const SizedBox());
      },
    ));
    await tester.pump();
    await tester.pump(); // the refund window has loaded
  }

  final button = find.text('Request Refund');

  testWidgets('a completed order opens the refund request for that order', (tester) async {
    final order = _order(OrderStatus.completed);
    await show(tester, order);

    await tester.tap(button);
    await tester.pump();

    expect(opened?.name, AppRoutes.customerRefundRequest);
    expect(opened?.arguments, same(order));
  });

  testWidgets('orders that are not completed have no button', (tester) async {
    for (final status in OrderStatus.values.where((s) => s != OrderStatus.completed)) {
      await show(tester, _order(status));
      expect(button, findsNothing, reason: status.name);
    }
  });

  testWidgets('the button goes away as soon as a request is sent', (tester) async {
    await show(tester, _order(OrderStatus.completed));
    expect(button, findsOneWidget);

    store.addRefund(_refund(RefundStatus.pending));
    await tester.pump();

    expect(button, findsNothing);
  });

  testWidgets('a rejected request can be retried', (tester) async {
    store.addRefund(_refund(RefundStatus.rejected));
    await show(tester, _order(OrderStatus.completed));
    expect(button, findsOneWidget);
  });

  testWidgets("another order's request does not hide the button", (tester) async {
    store.addRefund(_refund(RefundStatus.pending, orderId: 'ORD-OTHER'));
    await show(tester, _order(OrderStatus.completed));
    expect(button, findsOneWidget);
  });

  group('refund window (owner setting, days after pickup)', () {
    DateTime daysAgo(double d) => DateTime.now().subtract(Duration(minutes: (d * 24 * 60).round()));

    testWidgets('inside the window the button is offered', (tester) async {
      refundDays = 7;
      await show(tester, _order(OrderStatus.completed, pickedUp: daysAgo(6.9)));
      expect(button, findsOneWidget);
    });

    testWidgets('after the window the button is replaced by the closing date', (tester) async {
      refundDays = 7;
      await show(tester, _order(OrderStatus.completed, pickedUp: daysAgo(8)));
      expect(button, findsNothing);
      expect(find.textContaining('up to 7 days after pickup'), findsOneWidget);
    });

    testWidgets('no limit set: an old order still offers the button', (tester) async {
      refundDays = null;
      await show(tester, _order(OrderStatus.completed, pickedUp: daysAgo(400)));
      expect(button, findsOneWidget);
    });

    testWidgets('the window counts from the first pickup, not a later one', (tester) async {
      refundDays = 7;
      final first = daysAgo(8);
      final order = Order(
        id: 'ORD-T1',
        date: first,
        status: OrderStatus.completed,
        branch: 'Branch',
        isDelivery: false,
        items: const [_item],
        deliveryFee: 0,
        paymentMethod: 'Cash on Counter Pickup',
        pointsEarned: 0,
        timeline: [
          OrderTimelineStep(label: 'Completed', description: '', time: '', status: OrderStatus.completed, at: first),
          OrderTimelineStep(label: 'Completed', description: '', time: '', status: OrderStatus.completed, at: daysAgo(1)),
        ],
      );
      expect(order.pickedUpAt, first);
      await show(tester, order);
      expect(button, findsNothing);
    });
  });

  test("the server's refund window message reaches the customer", () {
    final e = AppErrors.from(
      Exception('Refunds can only be requested within 7 days after pickup. This order was picked up on November 1, 2026.'),
      scope: ErrorScope.refund,
    );
    expect(e.kind, AppErrorKind.refundFailed);
    expect(e.message, contains('within 7 days after pickup'));
  });
}
