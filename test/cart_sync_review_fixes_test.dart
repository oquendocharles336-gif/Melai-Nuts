import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import 'package:melai_nuts/data/models/product.dart';
import 'package:melai_nuts/data/repositories/cart_repository.dart';
import 'package:melai_nuts/features/customer/cart_controller.dart';
import 'package:melai_nuts/features/customer/screens/cart_screen.dart';
import 'package:melai_nuts/features/customer/screens/checkout_screen.dart' show checkoutFingerprint;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Review fixes 1 and 2:
///  1. a saved cart must survive sign-in / cold start while the catalog is
///     not loaded (or can't load), and the next edit must sync every line;
///  2. a cart the server refuses must not be retried forever, the screen
///     must show the server's cart, and checkout must wait for a clean cart.

const _pricing = CartPricing(
  subtotal: 0,
  voucherDiscount: 0,
  loyaltyDiscount: 0,
  deliveryFee: 0,
  total: 0,
  voucherCode: null,
  redeemPoints: false,
  loyaltyPointsBalance: 0,
  loyaltyPointsUsed: 0,
);

CartRemoteItem _item(String product, String variant, int qty, {double price = 100}) => CartRemoteItem(
      productId: product,
      variantId: variant,
      variantLabel: '100g',
      quantity: qty,
      currentPrice: price,
    );

CartRemoteState _state(List<CartRemoteItem> items) => CartRemoteState(
      cartId: 'cart-1',
      branchId: 'branch-1',
      voucherCode: null,
      redeemPoints: false,
      items: items,
      pricing: _pricing,
    );

Product _product(String id, String variantId) => Product.fromRow(
      {'id': id, 'name': 'Product $id', 'price': 100, 'category_id': 'c', 'is_active': true},
      variantRows: [
        {'id': variantId, 'label': '100g', 'price': 100},
      ],
      stockByVariantId: {variantId: 50},
      branchAvailability: const [],
      totalStock: 50,
    );

/// Stands in for the server: keeps the cart it last accepted.
class _FakeCartRepository extends CartRepository {
  _FakeCartRepository() : super.forTesting();

  CartRemoteState? server;
  final List<List<Map<String, dynamic>>> syncs = [];
  Object? failWith;
  int loads = 0;

  @override
  Future<CartRemoteState?> loadOpenCart({required String branchId}) async {
    loads++;
    return server;
  }

  @override
  Future<CartRemoteState> syncCart({
    required String branchId,
    required List<Map<String, dynamic>> items,
    String? voucherCode,
    required bool redeemPoints,
  }) async {
    syncs.add(items);
    final error = failWith;
    if (error != null) throw error;
    // Like sync_customer_cart: the server cart becomes exactly these lines.
    server = _state([
      for (final i in items) _item(i['product_id'] as String, i['variant_id'] as String, i['quantity'] as int),
    ]);
    return server!;
  }
}

void main() {
  final cart = CartController.instance;
  late _FakeCartRepository repo;
  late Map<String, String> storage;
  late int catalogLoads;
  final originalLoader = cart.catalogLoader;

  setUp(() {
    kProducts.clear();
    repo = _FakeCartRepository();
    CartRepository.debugInstance = repo;
    storage = {};
    cart.debugSnapshotStorage = storage;
    catalogLoads = 0;
    // Offline: the catalog cannot load, kProducts stays empty.
    cart.catalogLoader = (_) async => catalogLoads++;
    cart.endSession();
  });

  tearDown(() {
    cart.endSession();
    cart.debugSnapshotStorage = null;
    cart.catalogLoader = originalLoader;
    CartRepository.debugReset();
    kProducts.clear();
  });

  group('fix 1: saved cart survives a missing catalog', () {
    test('tryFindProductById returns null instead of a placeholder', () {
      expect(tryFindProductById('nope'), isNull);
      kProducts.add(_product('p1', 'v1'));
      expect(tryFindProductById('p1')?.id, 'p1');
    });

    test('hydrate keeps both server lines with an empty catalog; the next add syncs all 3', () async {
      repo.server = _state([_item('p1', 'v1', 2), _item('p2', 'v2', 1)]);

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(catalogLoads, 1, reason: 'hydrate loads the catalog first when it is empty');
      expect(cart.lines.length, 2);
      expect(cart.lines.map((l) => l.quantity), [2, 1]);

      final third = _product('p3', 'v3');
      final added = cart.addProduct(third, third.variants.first);
      expect(added.ok, isTrue);
      expect(await cart.flush(), isNull);

      expect(repo.syncs.last.length, 3, reason: 'the sync must not delete the saved lines');
      expect(repo.server!.items.map((i) => i.productId).toSet(), {'p1', 'p2', 'p3'});
    });

    test('server lines with quantity 0 or less are skipped', () async {
      repo.server = _state([_item('p1', 'v1', 2), _item('p2', 'v2', 0)]);
      await cart.hydrate('uid-1', branchId: 'branch-1');
      expect(cart.lines.map((l) => l.product.id), ['p1']);
    });

    test('the device snapshot falls back to its saved product when the catalog misses', () async {
      final saved = _product('p9', 'v9');
      storage['melai_cart_v3_uid-1_branch-1'] = jsonEncode({
        'cart_id': 'cart-1',
        'dirty': true,
        'items': [
          {
            'product_id': 'p9',
            'variant_id': 'v9',
            'variant_label': '100g',
            'quantity': 3,
            'unit_price': 100,
            'product_snapshot': {
              'id': saved.id,
              'name': saved.name,
              'variants': [
                {'id': 'v9', 'label': '100g', 'price': 100},
              ],
            },
          },
          // No quantity saved: skipped, never turned into a 0-quantity line.
          {'product_id': 'p8', 'variant_id': 'v8', 'variant_label': '100g'},
        ],
      });
      repo.server = null;

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(repo.syncs, isNotEmpty, reason: 'unsynced local edits are pushed');
      expect(repo.syncs.first, [
        {'product_id': 'p9', 'variant_id': 'v9', 'quantity': 3},
      ]);
      expect(cart.lines.single.product.name, 'Product p9');
    });
  });

  group('fix 2: refused carts and checkout', () {
    test('a refused sync stops retrying, shows the server cart, and returns the message', () async {
      repo.server = _state([_item('p1', 'v1', 1)]);
      await cart.hydrate('uid-1', branchId: 'branch-1');
      final lineId = cart.lines.single.id;

      repo.failWith = PostgrestException(
        message: 'The requested quantity is not available at this branch.',
        code: 'P0001',
      );
      await cart.updateQuantity(lineId, 40);

      expect(repo.syncs.length, 1);
      expect(cart.debugRetryScheduled, isFalse, reason: 'the same refused cart must not be resent every 15 s');
      expect(cart.hasUnsyncedChanges, isFalse);
      expect(cart.lines.single.quantity, 1, reason: 'the screen shows what the server really holds');
      expect(cart.lastError, isNotNull);
      expect(cartBlocksCheckout(cart), isFalse);
    });

    test('a connection failure keeps the edit, retries later, and blocks checkout', () async {
      repo.server = _state([_item('p1', 'v1', 1)]);
      await cart.hydrate('uid-1', branchId: 'branch-1');
      final lineId = cart.lines.single.id;

      repo.failWith = Exception('SocketException: Failed host lookup');
      await cart.updateQuantity(lineId, 2);

      expect(cart.debugRetryScheduled, isTrue);
      expect(cart.hasUnsyncedChanges, isTrue);
      expect(cart.lines.single.quantity, 2);
      expect(cartBlocksCheckout(cart), isTrue);
      expect(checkoutBlockedReason(cart), isNotNull);
      expect(await cart.flush(), isNotNull, reason: 'checkout must not call place_order');

      repo.failWith = null;
      expect(await cart.flush(), isNull);
      expect(cartBlocksCheckout(cart), isFalse);
      expect(repo.server!.items.single.quantity, 2);
    });

    test('server refusals are told apart from connection problems', () {
      expect(CartController.isServerRefusal(PostgrestException(message: 'One of the cart items is no longer available.', code: 'P0001')), isTrue);
      expect(CartController.isServerRefusal(PostgrestException(message: 'JWT expired', code: 'PGRST301')), isFalse);
      expect(CartController.isServerRefusal(PostgrestException(message: 'upstream', code: '503')), isFalse);
      expect(CartController.isServerRefusal(Exception('SocketException: Failed host lookup')), isFalse);
    });
  });

  group('fix 5: the checkout fingerprint includes the cart', () {
    String fp() => checkoutFingerprint(
          cart: cart,
          isDelivery: false,
          deliveryAddressId: null,
          pinLat: null,
          pinLng: null,
          paymentLabel: 'Cash on Counter Pickup',
          notes: '',
        );

    test('changes with the lines, the voucher and the points choice', () {
      cart.debugBind('uid-1', branchId: 'branch-1');
      final p1 = _product('p1', 'v1');
      final p2 = _product('p2', 'v2');
      cart.addProduct(p1, p1.variants.first);
      final one = fp();
      cart.addProduct(p1, p1.variants.first);
      final two = fp();
      expect(two, isNot(one), reason: 'quantity changed');
      cart.addProduct(p2, p2.variants.first);
      final withP2 = fp();
      expect(withP2, isNot(two), reason: 'line added');
      cart.appliedVoucherCode = 'SAVE10';
      expect(fp(), isNot(withP2), reason: 'voucher');
      final withVoucher = fp();
      cart.redeemPoints = true;
      expect(fp(), isNot(withVoucher), reason: 'points');
    });
  });
}
