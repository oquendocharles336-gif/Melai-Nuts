import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/customer_data_store.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/repositories/refunds_repository.dart';
import 'package:melai_nuts/features/customer/screens/order_details_screen.dart';

// The order details screen follows the live order list: when staff complete the
// order at pickup, "Completed" appears in its status and timeline without
// leaving the screen.

const _item = OrderItem(productName: 'Nut', variantLabel: 'Regular', quantity: 1, unitPrice: 100);

OrderTimelineStep _step(OrderStatus s, DateTime at) =>
    OrderTimelineStep(label: s.label, description: 'Order ${s.label.toLowerCase()}', time: '', done: true, status: s, at: at);

Order _order(OrderStatus status, List<OrderTimelineStep> timeline) => Order(
      id: 'ORD-LIVE1',
      date: DateTime(2026, 11, 19, 10),
      timeline: timeline,
      status: status,
      branch: 'Branch',
      isDelivery: false,
      items: const [_item],
      deliveryFee: 0,
      paymentMethod: 'Cash on Counter Pickup',
      pointsEarned: 0,
    );

void main() {
  final store = CustomerDataStore.instance;

  setUp(() {
    store.orders.clear();
    store.refunds.clear();
    RefundsRepository.refundDaysOverride = () async => null;
  });
  tearDown(() {
    store.orders.clear();
    RefundsRepository.refundDaysOverride = null;
  });

  testWidgets('a pickup order turns Completed on screen when the live order changes', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final placed = DateTime(2026, 11, 19, 10);
    final ready = _order(OrderStatus.readyForPickup, [
      _step(OrderStatus.pending, placed),
      _step(OrderStatus.readyForPickup, placed.add(const Duration(minutes: 30))),
    ]);
    store.orders.add(ready);

    await tester.pumpWidget(MaterialApp(home: OrderDetailsScreen(order: ready)));
    await tester.pump();
    expect(find.text('Completed'), findsNothing);

    // Realtime brings the new row (the store re-reads the orders and notifies).
    store.orders
      ..clear()
      ..add(_order(OrderStatus.completed, [
        ...ready.timeline,
        _step(OrderStatus.completed, placed.add(const Duration(minutes: 45))),
      ]));
    store.setAddresses(const []); // any store change notifies its listeners
    await tester.pump();
    await tester.pump();

    expect(find.text('Completed'), findsWidgets);
  });

  testWidgets('an order the store does not have yet shows the one it was opened with', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final o = _order(OrderStatus.preparing, [_step(OrderStatus.preparing, DateTime(2026, 11, 19, 10))]);
    await tester.pumpWidget(MaterialApp(home: OrderDetailsScreen(order: o)));
    await tester.pump();
    expect(find.text('Preparing'), findsWidgets);
  });
}
