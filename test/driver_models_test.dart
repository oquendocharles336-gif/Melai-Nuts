import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/delivery.dart';
import 'package:melai_nuts/data/repositories/driver_repository.dart';

// Parsing of the driver-module JSON (supabase/migrations/20261010010000_driver_module.sql).
void main() {
  group('Delivery.fromJson with driver fields', () {
    final json = <String, dynamic>{
      'id': 'DEL-1001',
      'branch': 'Calamba Branch',
      'branch_id': 'b-1',
      'vehicle': 'Motorbike',
      'rider_name': 'Rider One',
      'status': 'inTransit',
      'created_at': '2026-10-10T02:00:00Z',
      'driver_uid': 'drv-1',
      'driver_status': 'in_transit',
      'tracking_active': true,
      'branch_latitude': 14.2117,
      'branch_longitude': 121.1653,
      'stops': [
        {
          'id': 's-1',
          'order_id': 'ORD-1',
          'customer_name': 'Cust',
          'address': '1 Test St',
          'latitude': 14.2,
          'longitude': 121.1,
          'contact_phone': '0917',
          'order_total': 130,
          'payment_method': 'cash',
          'payment_status': 'pending',
          'sequence_index': 0,
          'status': 'failed',
          'issue_reason': 'Nobody home',
          'items': ['1x Nut'],
        },
      ],
    };

    test('reads run-level driver fields', () {
      final d = Delivery.fromJson(json);
      expect(d.driverUid, 'drv-1');
      expect(d.driverStatus, 'in_transit');
      expect(d.trackingActive, isTrue);
      expect(d.branchLatitude, closeTo(14.2117, 1e-9));
    });

    test('reads stop fields and the new failed status', () {
      final s = Delivery.fromJson(json).stops.single;
      expect(s.status, StopStatus.failed);
      expect(s.status.label, 'Failed');
      expect(s.isFinished, isTrue);
      expect(s.orderTotal, 130);
      expect(s.needsCashCollection, isTrue);
      expect(s.latitude, closeTo(14.2, 1e-9));
    });

    test('older servers without driver fields still parse', () {
      final old = Map<String, dynamic>.from(json)
        ..remove('driver_uid')
        ..remove('driver_status')
        ..remove('tracking_active');
      final d = Delivery.fromJson(old);
      expect(d.driverUid, isNull);
      expect(d.trackingActive, isFalse);
    });
  });

  group('DriverContext.fromJson', () {
    test('active driver', () {
      final c = DriverContext.fromJson({
        'status': 'active',
        'profile': {'full_name': 'Rider One', 'branch': 'Calamba Branch', 'is_available': true},
      });
      expect(c.isActive, isTrue);
      expect(c.fullName, 'Rider One');
      expect(c.isAvailable, isTrue);
    });

    test('not provisioned has a message and no profile', () {
      final c = DriverContext.fromJson({'status': 'not_provisioned'});
      expect(c.isActive, isFalse);
      expect(c.statusMessage, contains('not set up'));
    });
  });
}
