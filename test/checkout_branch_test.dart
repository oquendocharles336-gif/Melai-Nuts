import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/branch_choice.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import 'package:melai_nuts/data/models/branch.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/data/models/product.dart';
import 'package:melai_nuts/data/repositories/cart_repository.dart';
import 'package:melai_nuts/features/customer/cart_controller.dart';
import 'package:melai_nuts/features/customer/widgets/branch_stock_notice.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

Branch _branch(
  String id, {
  double? lat,
  double? lng,
  bool active = true,
  bool pickup = true,
  bool warehouse = false,
}) =>
    Branch.fromRow({
      'id': id,
      'name': id,
      'address': '',
      'latitude': lat,
      'longitude': lng,
      'is_active': active,
      'supports_delivery': false,
      'supports_pickup': pickup,
      'is_warehouse': warehouse,
    });

Order _order(String? branchId, DateTime date, {OrderStatus status = OrderStatus.completed}) => Order(
      id: 'ORD-$date',
      date: date,
      status: status,
      branch: branchId ?? '',
      branchId: branchId,
      isDelivery: false,
      items: const [],
      deliveryFee: 0,
      paymentMethod: 'Cash on Counter Pickup',
      pointsEarned: 0,
    );

const _pricing = CartPricing(
  subtotal: 100,
  voucherDiscount: 0,
  loyaltyDiscount: 0,
  deliveryFee: 0,
  total: 100,
  voucherCode: null,
  redeemPoints: false,
  loyaltyPointsBalance: 0,
  loyaltyPointsUsed: 0,
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

/// Stands in for the server: one open cart per branch.
class _FakeCartRepository extends CartRepository {
  _FakeCartRepository() : super.forTesting();

  final Map<String, List<Map<String, dynamic>>> carts = {};
  final Map<String, String?> vouchers = {};
  final Map<String, bool> points = {};
  String? offlineBranch;
  String? failClearing;
  bool refuseDiscounts = false;
  bool refuseEverything = false;

  @override
  Future<CartRemoteState?> loadOpenCart({required String branchId}) async => null;

  @override
  Future<CartRemoteState> syncCart({
    required String branchId,
    required List<Map<String, dynamic>> items,
    String? voucherCode,
    required bool redeemPoints,
  }) async {
    if (branchId == offlineBranch) throw StateError('offline');
    if (items.isEmpty && branchId == failClearing) throw StateError('offline');
    if (refuseEverything || (refuseDiscounts && (voucherCode != null || redeemPoints))) {
      throw const PostgrestException(message: 'This voucher requires a minimum subtotal.', code: 'P0001');
    }
    carts[branchId] = items;
    vouchers[branchId] = voucherCode;
    points[branchId] = redeemPoints;
    return CartRemoteState(
      cartId: 'cart-$branchId',
      branchId: branchId,
      voucherCode: voucherCode,
      redeemPoints: redeemPoints,
      items: [
        for (final i in items)
          CartRemoteItem(
            productId: i['product_id'] as String,
            variantId: i['variant_id'] as String,
            variantLabel: '100g',
            quantity: i['quantity'] as int,
            currentPrice: 100,
          ),
      ],
      pricing: _pricing,
    );
  }
}

void main() {
  final near = _branch('near', lat: 14.21, lng: 121.15);
  final middle = _branch('middle', lat: 14.18, lng: 121.26);
  final far = _branch('far', lat: 14.25, lng: 121.39);
  final all = [far, near, middle];

  group('chooseBranch', () {
    test('the nearest open branch comes first, with its distance', () {
      final choice = chooseBranch(
        branches: all,
        latitude: 14.21,
        longitude: 121.15,
        lastOrderBranch: 'far',
        savedBranch: 'middle',
      )!;
      expect(choice.branch.id, 'near');
      expect(choice.reason, BranchChoiceReason.nearest);
      expect(choice.distanceKm, closeTo(0, 0.01));
    });

    test('skips closed, no-pickup and warehouse branches', () {
      final closed = _branch('closed', lat: 14.21, lng: 121.15, active: false);
      final noPickup = _branch('no-pickup', lat: 14.21, lng: 121.15, pickup: false);
      final warehouse = _branch('warehouse', lat: 14.21, lng: 121.15, warehouse: true);
      final choice = chooseBranch(
        branches: [closed, noPickup, warehouse, far, middle],
        latitude: 14.21,
        longitude: 121.15,
      )!;
      expect(choice.branch.id, 'middle');
    });

    test('without a location: the last order, then the saved branch', () {
      expect(
        chooseBranch(branches: all, lastOrderBranch: 'far', savedBranch: 'near')!.reason,
        BranchChoiceReason.lastOrder,
      );
      final saved = chooseBranch(branches: all, lastOrderBranch: 'gone', savedBranch: 'near')!;
      expect(saved.branch.id, 'near');
      expect(saved.reason, BranchChoiceReason.savedBranch);
    });

    test('nothing to go on: no branch at all, so location is needed', () {
      expect(chooseBranch(branches: all), isNull);
      expect(chooseBranch(branches: all, lastOrderBranch: 'gone', savedBranch: 'gone'), isNull);
    });

    test('a branch that closed is not used from the last order or saved branch', () {
      final closed = _branch('closed', lat: 14.21, lng: 121.15, active: false);
      expect(chooseBranch(branches: [closed, far, near], lastOrderBranch: 'closed', savedBranch: 'closed'), isNull);
    });

    test('with only one open branch, no location is needed', () {
      final closed = _branch('closed', active: false);
      final choice = chooseBranch(branches: [closed, far])!;
      expect(choice.branch.id, 'far');
      expect(choice.reason, BranchChoiceReason.onlyBranch);
    });

    group('switching margin', () {
      // 0.009 degrees of latitude is about 1 km.
      final a = _branch('a', lat: 14.000, lng: 121.0);
      final b = _branch('b', lat: 14.100, lng: 121.0);
      const midpoint = 14.050;

      test('a slightly closer branch does not take the cart', () {
        final choice = chooseBranch(
          branches: [a, b],
          latitude: midpoint + 0.002,
          longitude: 121.0,
          currentBranch: 'a',
        )!;
        expect(choice.branch.id, 'a');
        expect(choice.reason, BranchChoiceReason.nearest);
      });

      test('a branch at least 1 km closer does', () {
        final choice = chooseBranch(
          branches: [a, b],
          latitude: midpoint + 0.01,
          longitude: 121.0,
          currentBranch: 'a',
        )!;
        expect(choice.branch.id, 'b');
      });

      test('the margin never keeps a closed branch', () {
        final closedA = _branch('a', lat: 14.000, lng: 121.0, active: false);
        final choice = chooseBranch(
          branches: [closedA, b],
          latitude: midpoint,
          longitude: 121.0,
          currentBranch: 'a',
        )!;
        expect(choice.branch.id, 'b');
      });
    });
  });

  group('lastOrderBranchId', () {
    test('is the newest order that was not cancelled', () {
      final orders = [
        _order('old', DateTime(2026, 1, 1)),
        _order('newest', DateTime(2026, 3, 1)),
        _order('cancelled', DateTime(2026, 4, 1), status: OrderStatus.cancelled),
      ];
      expect(lastOrderBranchId(orders), 'newest');
    });

    test('is null with no usable order', () {
      expect(lastOrderBranchId(const []), isNull);
      expect(lastOrderBranchId([_order(null, DateTime(2026))]), isNull);
    });
  });

  group('shortfallsAt', () {
    const needs = [
      CartNeed(variantId: 'v1', name: 'Gift Box', quantity: 2),
      CartNeed(variantId: 'v2', name: 'Cashew', quantity: 1),
    ];

    test('reports only what a branch cannot fill', () {
      final short = shortfallsAt('near', needs, {
        'near': {'v1': 1, 'v2': 5},
      });
      expect(short.single.name, 'Gift Box');
      expect(short.single.available, 1);
    });

    test('a variant the branch does not sell counts as none', () {
      final short = shortfallsAt('near', needs, {
        'near': {'v1': 2},
      });
      expect(short.single.name, 'Cashew');
      expect(short.single.available, 0);
    });
  });

  group('wording', () {
    for (final locale in const ['en', 'fil']) {
      test('$locale: the reason and the changes use the real values', () {
        final t = lookupAppLocalizations(Locale(locale));
        final nearest = orderingFromText(t, BranchChoice(near, BranchChoiceReason.nearest, distanceKm: 2.1));
        final lastOrder = orderingFromText(t, BranchChoice(near, BranchChoiceReason.lastOrder));
        final saved = orderingFromText(t, BranchChoice(near, BranchChoiceReason.savedBranch));
        expect(nearest, contains('near'));
        expect(lastOrder, contains('near'));
        expect(nearest, isNot(lastOrder));
        expect(saved, isNot(nearest));
        expect(saved, isNot(lastOrder));

        final lines = moveNoticeLines(
          t,
          const CartMoveNotice(
            branchName: 'Calamba',
            droppedDiscounts: true,
            shortfalls: [
              StockShortfall(name: 'Gift Box', needed: 4, available: 1),
              StockShortfall(name: 'Cashew', needed: 1, available: 0),
            ],
          ),
        );
        expect(lines, hasLength(4));
        expect(lines[0], contains('Calamba'));
        expect(lines[1], contains('Gift Box'));
        expect(lines[1], contains('1'));
        expect(lines[2], contains('Cashew'));
        expect(lines[3], t.cartDiscountsRemoved);
      });
    }

    test('English matches the agreed text', () {
      final t = lookupAppLocalizations(const Locale('en'));
      expect(
        orderingFromText(t, BranchChoice(_branch('Santa Cruz'), BranchChoiceReason.nearest)),
        'Ordering from: Santa Cruz (nearest to you)',
      );
      expect(t.branchLocationNeeded, 'Turn on location so we can use your nearest branch.');
    });
  });

  group('moveToBranch', () {
    final cart = CartController.instance;
    final originalStock = cart.stockLoader;
    late _FakeCartRepository repo;
    late Map<String, String> storage;
    final product = _product('p1', 'v1');
    final other = _product('p2', 'v2');
    BranchStock? shelf;

    setUp(() async {
      kProducts.clear();
      repo = _FakeCartRepository();
      CartRepository.debugInstance = repo;
      storage = {};
      cart.debugSnapshotStorage = storage;
      shelf = {
        'a': {'v1': 10, 'v2': 10},
        'b': {'v1': 10, 'v2': 10},
      };
      cart.stockLoader = (_) async => shelf;
      cart.endSession();
      cart.debugBind('uid-1', branchId: 'a');
      cart.addProduct(product, product.variants.first, quantity: 3);
      cart.addProduct(other, other.variants.first);
      await cart.flush();
    });

    tearDown(() {
      cart.endSession();
      cart.debugSnapshotStorage = null;
      cart.stockLoader = originalStock;
      CartRepository.debugReset();
      kProducts.clear();
    });

    test('the lines follow the customer and the old cart is emptied', () async {
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isTrue);
      expect(result.cartChanged, isFalse);
      expect(cart.branchId, 'b');
      expect(cart.cartId, 'cart-b');
      expect(cart.itemCount, 4);
      expect(repo.carts['b'], hasLength(2));
      expect(repo.carts['a'], isEmpty);
      expect(cart.hasUnsyncedChanges, isFalse);
    });

    test('moving replaces an older cart at the new branch', () async {
      repo.carts['b'] = [
        {'product_id': 'old', 'variant_id': 'old', 'quantity': 9},
      ];
      await cart.moveToBranch('b');
      expect(repo.carts['b']!.map((i) => i['variant_id']), ['v1', 'v2']);
    });

    test('quantities are lowered and missing items removed, and the result says so', () async {
      shelf = {
        'b': {'v1': 1},
      };
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isTrue);
      expect(result.cartChanged, isTrue);
      expect(result.shortfalls.map((s) => s.available), [1, 0]);
      expect(cart.branchId, 'b');
      expect(cart.lines.single.variant.id, 'v1');
      expect(cart.lines.single.quantity, 1);
      expect(repo.carts['b']!.single['quantity'], 1);
      expect(repo.carts['a'], isEmpty);
    });

    test('a branch with none of it leaves an empty cart there, and says so', () async {
      shelf = {'b': {}};
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isTrue);
      expect(result.shortfalls, hasLength(2));
      expect(cart.lines, isEmpty);
      expect(cart.branchId, 'b');
    });

    test('a voucher and points that no longer apply are dropped, and the result says so', () async {
      cart.appliedVoucherCode = 'SAVE10';
      repo.refuseDiscounts = true;
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isTrue);
      expect(result.droppedDiscounts, isTrue);
      expect(cart.branchId, 'b');
      expect(cart.appliedVoucherCode, isNull);
      expect(repo.vouchers['b'], isNull);
    });

    test('a voucher that still applies moves with the cart', () async {
      cart.appliedVoucherCode = 'SAVE10';
      final result = await cart.moveToBranch('b');
      expect(result.droppedDiscounts, isFalse);
      expect(cart.appliedVoucherCode, 'SAVE10');
      expect(repo.vouchers['b'], 'SAVE10');
    });

    test('unreadable stock leaves the cart where it is', () async {
      shelf = null;
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isFalse);
      expect(result.message, isNotNull);
      expect(cart.branchId, 'a');
      expect(cart.itemCount, 4);
      expect(repo.carts.containsKey('b'), isFalse);
    });

    test('an unreachable server leaves the cart where it is', () async {
      repo.offlineBranch = 'b';
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isFalse);
      expect(cart.branchId, 'a');
      expect(cart.cartId, 'cart-a');
      expect(cart.itemCount, 4);
      expect(repo.carts['a'], isNotEmpty);
    });

    test('a refusal with no discounts to drop leaves the cart where it is', () async {
      repo.refuseEverything = true;
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isFalse);
      expect(cart.branchId, 'a');
    });

    test('a failure emptying the old cart does not undo the move', () async {
      repo.failClearing = 'a';
      final result = await cart.moveToBranch('b');
      expect(result.isMoved, isTrue);
      expect(cart.branchId, 'b');
      expect(cart.itemCount, 4);
    });

    test('the saved copy moves too', () async {
      await cart.moveToBranch('b');
      expect(storage.keys.where((k) => k.endsWith('_a')), isEmpty);
      expect(storage.keys.where((k) => k.endsWith('_b')), hasLength(1));
    });

    test('staying at the same branch does nothing', () async {
      final result = await cart.moveToBranch('a');
      expect(result.isMoved, isTrue);
      expect(repo.carts.containsKey('b'), isFalse);
      expect(cart.itemCount, 4);
    });
  });
}
