import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/inventory_item.dart';
import 'package:melai_nuts/data/repositories/products_repository.dart';

/// Review fix 8: a branch_inventory row does not by itself mean "sold here";
/// `is_carried = false` must read as "not sold here", not "out of stock".
void main() {
  test('no row -> not sold here', () {
    expect(LiveStock.fromRows(const []).notStockedHere, isTrue);
  });

  test('a row the branch does not carry -> not sold here (not "out of stock")', () {
    final s = LiveStock.fromRows(const [
      {'quantity': 0, 'is_carried': false},
    ]);
    expect(s.notStockedHere, isTrue);
    expect(s.quantity, isNull);
  });

  test('a carried row with 0 -> genuinely out of stock', () {
    final s = LiveStock.fromRows(const [
      {'quantity': 0, 'is_carried': true},
    ]);
    expect(s.notStockedHere, isFalse);
    expect(s.quantity, 0);
  });

  test('rows from a database without the column still count as carried', () {
    expect(LiveStock.fromRows(const [
      {'quantity': 4},
    ]).quantity, 4);
  });

  group('staff inventory: "not sold here" is not "out of stock"', () {
    InventoryItem item({required int qty, bool carried = true, int? threshold = 5}) => InventoryItem(
          productId: 'p1',
          variantId: 'v1',
          productName: 'Garlic Peanuts',
          variantLabel: '100g',
          sku: 'GP-100',
          categoryId: 'c1',
          price: 100,
          quantity: qty,
          restockThreshold: threshold,
          batchedQuantity: 0,
          branchId: 'b1',
          batches: const [],
          isCarried: carried,
        );

    test('an item the branch does not sell is not sold here, not out of stock or low', () {
      final i = item(qty: 0, carried: false);
      expect(i.isNotSoldHere, isTrue);
      expect(i.isOutOfStock, isFalse);
      expect(i.isLowStock, isFalse);
      expect(i.needsRestock, isFalse, reason: 'left out of the low / out-of-stock counts');
      expect(i.hasNoStock, isTrue, reason: 'still cannot be sold at the register');
    });

    test('a sold item at 0 is out of stock and needs restock', () {
      final i = item(qty: 0);
      expect(i.isNotSoldHere, isFalse);
      expect(i.isOutOfStock, isTrue);
      expect(i.needsRestock, isTrue);
    });

    test('a sold item at or below its level is low', () {
      expect(item(qty: 3).isLowStock, isTrue);
      expect(item(qty: 9).needsRestock, isFalse);
    });

    test('items are carried unless the database says otherwise (older databases)', () {
      final i = InventoryItem(
        productId: 'p1', variantId: 'v1', productName: 'X', variantLabel: '', sku: '', categoryId: '',
        price: 1, quantity: 0, restockThreshold: null, batchedQuantity: 0, branchId: 'b1', batches: const [],
      );
      expect(i.isCarried, isTrue);
      expect(i.isOutOfStock, isTrue);
    });
  });
}
