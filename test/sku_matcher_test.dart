import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/inventory_item.dart';
import 'package:melai_nuts/features/staff/barcode/sku_matcher.dart';

InventoryItem _item(String variantId, String sku) => InventoryItem(
      productId: 'p-$variantId',
      variantId: variantId,
      productName: 'Test product $variantId',
      variantLabel: 'Regular',
      sku: sku,
      categoryId: 'c',
      price: 10,
      quantity: 5,
      restockThreshold: null,
      batchedQuantity: 0,
      branchId: 'b',
      batches: const [],
    );

void main() {
  final items = [_item('v1', 'MN-100'), _item('v2', ''), _item('v3', '4800016644443')];

  test('an exact SKU / barcode matches, ignoring case and spaces', () {
    expect(matchSku(items, 'mn-100')?.variantId, 'v1');
    expect(matchSku(items, ' 4800016644443 ')?.variantId, 'v3');
  });

  test('no match is null, never the closest item', () {
    expect(matchSku(items, 'MN-10'), isNull);
    expect(matchSku(items, '480001664444'), isNull);
  });

  test('empty codes and items without a SKU never match', () {
    expect(matchSku(items, ''), isNull);
    expect(matchSku(items, '   '), isNull);
  });
}
