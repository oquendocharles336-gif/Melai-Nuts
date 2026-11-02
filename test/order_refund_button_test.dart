import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/routes.dart';
import 'package:melai_nuts/core/services/customer_data_store.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/models/refund.dart';
import 'package:melai_nuts/features/customer/screens/order_details_screen.dart';

const _item = OrderItem(productName: 'Nut', variantLabel: 'Regular', quantity: 1, unitPrice: 100);

Order _order(OrderStatus status) => Order(
      id: 'ORD-T1',
      date: DateTime(2026, 11, 1),
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

  setUp(() {
    opened = null;
    store.refunds.clear();
  });
  tearDown(store.refunds.clear);

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
}
