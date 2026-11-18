import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/features/notifications/notification_targets.dart';
import 'package:melai_nuts/features/notifications/push_tap_router.dart';

void main() {
  group('PushTap', () {
    test('a staff order push goes to the order in its reference', () {
      final tap = PushTap.from(
        {'kind': 'staff.order', 'category': 'order', 'reference': 'ORD-1040', 'notification_id': 'n1'},
        title: 'New pickup order ORD-9999',
      );
      expect(tap.forStaff, isTrue);
      expect(tap.orderId, 'ORD-1040');
      expect(tap.notificationId, 'n1');
    });

    test('a staff push about something else names no order', () {
      final tap = PushTap.from({'kind': 'staff.inventory', 'category': 'inventory', 'reference': 'x-1'});
      expect(tap.forStaff, isTrue);
      expect(tap.category, 'inventory');
      expect(tap.orderId, isNull);
    });

    test('a staff expiry push keeps its reference so it opens Expiring Soon', () {
      final tap = PushTap.from({'kind': 'staff.inventory', 'category': 'inventory', 'reference': 'expiry:b-1'});
      expect(tap.reference, 'expiry:b-1');
      expect(tap.orderId, isNull);
    });

    test('a customer push finds the order in its text', () {
      final title = PushTap.from(
        {'kind': 'customer.order', 'category': 'order', 'notification_id': 'n2'},
        title: 'Order ORD-1034 is ready for pickup',
        body: 'You can pick it up now.',
      );
      expect(title.forStaff, isFalse);
      expect(title.orderId, 'ORD-1034');

      final body = PushTap.from(
        {'kind': 'customer.payment'},
        title: 'Downpayment received',
        body: 'We received ₱144.00 for order ORD-1036.',
      );
      expect(body.orderId, 'ORD-1036');
    });

    test('a customer push with no order opens no order', () {
      final tap = PushTap.from({'kind': 'customer.general', 'notification_id': 'n3'}, title: 'Hello');
      expect(tap.orderId, isNull);
      expect(tap.notificationId, 'n3');
    });

    test('a push with no details is treated as a customer push and does not fail', () {
      final tap = PushTap.from(const {});
      expect(tap.forStaff, isFalse);
      expect(tap.orderId, isNull);
      expect(tap.notificationId, isNull);
    });
  });

  group('NotificationTargets.orderIdIn', () {
    test('finds the order a notification is about', () {
      expect(NotificationTargets.orderIdIn('Order ORD-1010 completed', 'Thank you for your order.'), 'ORD-1010');
      expect(NotificationTargets.orderIdIn('Refund approved', 'Your refund for ORD-77 was approved.'), 'ORD-77');
      expect(NotificationTargets.orderIdIn('Weekend promo', '10% off all nuts.'), isNull);
    });
  });
}
