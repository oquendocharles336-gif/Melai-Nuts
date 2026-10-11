import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/branch.dart';

Map<String, dynamic> _row({bool warehouse = false, bool pickup = true, bool delivery = false}) => {
      'id': 'b1', 'name': 'Shop', 'address': null, 'is_active': true,
      'supports_pickup': pickup, 'supports_delivery': delivery, 'delivery_fee': 0, 'is_warehouse': warehouse,
    };

void main() {
  test('a warehouse is never offered to customers', () {
    expect(Branch.fromRow(_row(warehouse: true, pickup: false)).servesCustomers, isFalse);
  });

  test('a shop with pickup or delivery is offered', () {
    expect(Branch.fromRow(_row()).servesCustomers, isTrue);
    expect(Branch.fromRow(_row(pickup: false, delivery: true)).servesCustomers, isTrue);
    expect(Branch.fromRow(_row(pickup: false, delivery: false)).servesCustomers, isFalse);
  });

  test('an older server without the column means "not a warehouse"', () {
    final row = _row()..remove('is_warehouse');
    expect(Branch.fromRow(row).isWarehouse, isFalse);
  });
}
