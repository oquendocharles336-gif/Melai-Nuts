import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/models/product.dart';
import 'package:melai_nuts/data/repositories/favorites_repository.dart';
import 'package:melai_nuts/data/repositories/storefront_settings_repository.dart';
import 'package:melai_nuts/features/customer/screens/repeat_order_screen.dart';

Product _product(String id, String name, List<Map<String, dynamic>> variants, Map<String, int> stock, {int? badge}) =>
    Product.fromRow(
      {'id': id, 'name': name, 'price': 100, 'category_id': 'c'},
      variantRows: variants,
      stockByVariantId: stock,
      branchAvailability: const [],
      totalStock: stock.values.fold(0, (a, b) => a + b),
      lowStockBadgeQty: badge,
    );

void main() {
  group('"Only N left" comes from real stock and the owner setting', () {
    test('Not set never shows it', () {
      expect(Product.stockLabelFor(2, null), 'In Stock');
      expect(Product.stockLabelFor(0, null), 'Out of Stock');
    });
    test('at or below the setting', () {
      expect(Product.stockLabelFor(3, 3), 'Only 3 left');
      expect(Product.stockLabelFor(1, 3), 'Only 1 left');
      expect(Product.stockLabelFor(4, 3), 'In Stock');
      expect(Product.stockLabelFor(0, 3), 'Out of Stock');
    });
    test('the product and its variant agree', () {
      final p = _product('p1', 'Nut', [
        {'id': 'v1', 'label': 'Regular', 'price': 100},
      ], {'v1': 2}, badge: 3);
      expect(p.stockLabel, 'Only 2 left');
      expect(p.isLowStock, isTrue);
      expect(p.variants.single.onlyLeft(3), 2);
      expect(p.variants.single.onlyLeft(null), isNull);
    });
    test('settings parse defensively', () {
      expect(StorefrontSettings.fromJson({'low_stock_badge_qty': 3}).lowStockBadgeQty, 3);
      expect(StorefrontSettings.fromJson({'low_stock_badge_qty': null}).lowStockBadgeQty, isNull);
      expect(StorefrontSettings.fromJson({'low_stock_badge_qty': 0}).lowStockBadgeQty, isNull);
      expect(StorefrontSettings.fromJson('garbage').lowStockBadgeQty, isNull);
    });
  });

  group('reorder matches past lines to today\'s catalogue', () {
    final catalog = [
      _product('p1', 'Garlic Peanuts (renamed)', [
        {'id': 'v1', 'label': '100g', 'price': 50},
        {'id': 'v2', 'label': '250g', 'price': 110},
      ], {'v1': 5, 'v2': 0}),
    ];
    test('by variant id, even after a rename', () {
      const item = OrderItem(productName: 'Garlic Peanuts', variantLabel: '250g', quantity: 1, unitPrice: 99,
          productId: 'p1', variantId: 'v2');
      final m = matchOrderLine(item, catalog)!;
      expect(m.product.id, 'p1');
      expect(m.variant!.id, 'v2');
    });
    test('old lines without ids fall back to exact names', () {
      const item = OrderItem(productName: 'garlic peanuts (renamed)', variantLabel: '100G', quantity: 1, unitPrice: 50);
      expect(matchOrderLine(item, catalog)!.variant!.id, 'v1');
    });
    test('a removed option is reported, never swapped', () {
      const item = OrderItem(productName: 'x', variantLabel: '1kg', quantity: 1, unitPrice: 1, productId: 'p1');
      final m = matchOrderLine(item, catalog)!;
      expect(m.variant, isNull);
    });
    test('a removed product is reported', () {
      const item = OrderItem(productName: 'Gone', variantLabel: '100g', quantity: 1, unitPrice: 1, productId: 'zz');
      expect(matchOrderLine(item, catalog), isNull);
    });
  });

  group('favourites', () {
    test('load and toggle follow the server', () async {
      final calls = <String>[];
      final repo = FavoritesRepository(rpc: (fn, params) async {
        calls.add(fn);
        if (fn == 'get_my_favorites') return ['p1'];
        return params!['p_product_id'] == 'p2';
      });
      await repo.load();
      expect(repo.contains('p1'), isTrue);
      expect(await repo.toggle('p2'), isTrue);
      expect(repo.contains('p2'), isTrue);
      expect(await repo.toggle('p1'), isTrue);
      expect(repo.contains('p1'), isFalse);
      expect(calls, ['get_my_favorites', 'toggle_favorite', 'toggle_favorite']);
    });
    test('a refused toggle puts the heart back', () async {
      final repo = FavoritesRepository(rpc: (fn, params) async {
        if (fn == 'get_my_favorites') return <String>[];
        throw Exception('This product is no longer available.');
      });
      await repo.load();
      expect(await repo.toggle('p9'), isFalse);
      expect(repo.contains('p9'), isFalse);
      expect(repo.lastError, isNotNull);
    });
    test('sign-out clears them', () async {
      final repo = FavoritesRepository(rpc: (fn, params) async => ['p1']);
      await repo.load();
      repo.clear();
      expect(repo.ids, isEmpty);
      expect(repo.isLoaded, isFalse);
    });
  });

  // Final-check fix 5: a product with no variants (e.g. created in the
  // Supabase dashboard) is kept by fromRow, so every screen must handle
  // `variants.isEmpty` instead of calling `variants.first`.
  group('a product with no variants', () {
    test('is kept with an empty variant list and safe defaults', () {
      final p = _product('p9', 'Plain Peanuts', const [], const {});
      expect(p.variants, isEmpty);
      expect(p.variantLabel, '');
      expect(p.costPrice, 0);
      expect(p.price, 100); // product-level price is still available to show
      expect(p.stockLabel, 'Out of Stock');
    });
  });
}

