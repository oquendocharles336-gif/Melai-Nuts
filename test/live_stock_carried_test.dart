import 'package:flutter_test/flutter_test.dart';
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
}
