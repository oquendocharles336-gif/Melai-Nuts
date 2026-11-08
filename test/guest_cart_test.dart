import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/post_sign_in.dart';
import 'package:melai_nuts/app/routes.dart';
import 'package:melai_nuts/core/services/branch_choice.dart';
import 'package:melai_nuts/core/theme/app_theme.dart';
import 'package:melai_nuts/core/widgets/motion.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import 'package:melai_nuts/data/models/product.dart';
import 'package:melai_nuts/data/models/user_role.dart';
import 'package:melai_nuts/data/repositories/cart_repository.dart';
import 'package:melai_nuts/features/customer/cart_controller.dart';
import 'package:melai_nuts/features/customer/widgets/product_card.dart';
import 'package:melai_nuts/features/customer/widgets/storefront_widgets.dart';

/// Guest cart: a customer can fill a cart before signing in. It stays on the
/// device, and when they sign in it joins the cart already on their account
/// (quantities added up, capped by live stock). Checkout then sends them
/// back to their cart.

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

CartRemoteItem _item(String product, String variant, int qty) => CartRemoteItem(
      productId: product,
      variantId: variant,
      variantLabel: '100g',
      quantity: qty,
      currentPrice: 100,
    );

CartRemoteState _state(List<CartRemoteItem> items) => CartRemoteState(
      cartId: 'cart-1',
      branchId: 'branch-1',
      voucherCode: null,
      redeemPoints: false,
      items: items,
      pricing: _pricing,
    );

Product _product(String id, String variantId, {List<String> tags = const [], String name = ''}) => Product.fromRow(
      {
        'id': id,
        'name': name.isEmpty ? 'Product $id' : name,
        'price': 100,
        'category_id': 'c',
        'is_active': true,
        'tags': tags,
      },
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
  Object? loadError;
  Object? syncError;

  @override
  Future<CartRemoteState?> loadOpenCart({required String branchId}) async {
    final error = loadError;
    if (error != null) throw error;
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
    final error = syncError;
    if (error != null) throw error;
    server = _state([
      for (final i in items) _item(i['product_id'] as String, i['variant_id'] as String, i['quantity'] as int),
    ]);
    return server!;
  }
}

Map<String, int> _quantities(CartController cart) => {for (final l in cart.lines) l.product.id: l.quantity};

void main() {
  group('guest cart joins the account cart at sign-in', () {
    final cart = CartController.instance;
    final originalStock = cart.stockLoader;
    final originalCatalog = cart.catalogLoader;
    late _FakeCartRepository repo;
    late Map<String, String> storage;
    BranchStock? shelf;
    final p1 = _product('p1', 'v1');
    final p2 = _product('p2', 'v2');
    final p3 = _product('p3', 'v3');

    setUp(() {
      kProducts
        ..clear()
        ..addAll([p1, p2, p3]);
      repo = _FakeCartRepository();
      CartRepository.debugInstance = repo;
      storage = {};
      cart.debugSnapshotStorage = storage;
      shelf = {
        'branch-1': {'v1': 10, 'v2': 10, 'v3': 10},
      };
      cart.stockLoader = (_) async => shelf;
      cart.catalogLoader = (_) async {};
      cart.endSession();
    });

    tearDown(() {
      cart.endSession();
      cart.debugSnapshotStorage = null;
      cart.stockLoader = originalStock;
      cart.catalogLoader = originalCatalog;
      CartRepository.debugReset();
      kProducts.clear();
    });

    /// A guest at branch-1 with [lines] in their cart, saved on the device.
    Future<void> guestWith(Map<Product, int> lines) async {
      await cart.startGuestSession();
      expect(await cart.switchBranch('branch-1'), isTrue);
      for (final entry in lines.entries) {
        expect(cart.addProduct(entry.key, entry.key.variants.first, quantity: entry.value).ok, isTrue);
      }
      await Future<void>.delayed(Duration.zero); // let the device save finish
    }

    test('a guest cart is saved on the device and never sent to the server', () async {
      await guestWith({p1: 2});
      expect(repo.syncs, isEmpty);
      expect(cart.hasUnsyncedChanges, isFalse);
      final saved = jsonDecode(storage[CartController.guestStorageKey]!) as Map;
      expect((saved['items'] as List).single['quantity'], 2);
    });

    test('same items add up, new ones are added, and the server gets the merged cart', () async {
      repo.server = _state([_item('p1', 'v1', 1), _item('p2', 'v2', 1)]);
      await guestWith({p1: 2, p3: 1});

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(cart.isGuest, isFalse);
      expect(_quantities(cart), {'p1': 3, 'p2': 1, 'p3': 1});
      expect(repo.server!.items.map((i) => '${i.productId}:${i.quantity}').toSet(), {'p1:3', 'p2:1', 'p3:1'});
      expect(cart.hasUnsyncedChanges, isFalse);
      expect(storage.containsKey(CartController.guestStorageKey), isFalse, reason: 'merged once, then removed');
      expect(cart.guestMergeNote, isNull);
    });

    test('quantities are capped by live stock, and the customer is told', () async {
      repo.server = _state([_item('p1', 'v1', 1)]);
      shelf = {
        'branch-1': {'v1': 2}, // p3 isn't on this shelf at all
      };
      await guestWith({p1: 3, p3: 1});

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(_quantities(cart), {'p1': 2});
      expect(cart.guestMergeNote, contains('lowered or left out'));
      cart.clearGuestMergeNote();
      expect(cart.guestMergeNote, isNull);
    });

    test('when stock cannot be read the lines are added as they are', () async {
      shelf = null;
      await guestWith({p1: 4});

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(_quantities(cart), {'p1': 4});
      expect(cart.guestMergeNote, isNull);
    });

    test('a guest cart saved before the app restarted still joins', () async {
      await guestWith({p2: 2});
      cart.endSession(); // app closed: memory gone, the device copy remains
      expect(cart.lines, isEmpty);

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(_quantities(cart), {'p2': 2});
    });

    test('if the account cart cannot load, the guest lines are kept for the retry', () async {
      await guestWith({p1: 2});
      repo.loadError = Exception('offline');
      repo.syncError = Exception('offline');

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(cart.hasLoadError, isTrue);
      expect(_quantities(cart), {'p1': 2});
      expect(cart.hasUnsyncedChanges, isTrue, reason: 'sent on the next try');
      expect(storage.containsKey(CartController.guestStorageKey), isFalse);
      final account = jsonDecode(storage['melai_cart_v3_uid-1_branch-1']!) as Map;
      expect(account['dirty'], isTrue);
      expect((account['items'] as List).single['quantity'], 2);
    });

    test('two loads at once add the guest lines only once', () async {
      await guestWith({p1: 2});
      cart.endSession(); // only the device copy is left
      await Future.wait([
        cart.hydrate('uid-1', branchId: 'branch-1'),
        cart.hydrate('uid-1', branchId: 'branch-1'),
      ]);
      expect(_quantities(cart), {'p1': 2});
    });

    test('a guest changing branch keeps their lines', () async {
      await guestWith({p1: 2});
      expect(await cart.switchBranch('branch-2'), isTrue);
      expect(cart.branchId, 'branch-2');
      expect(_quantities(cart), {'p1': 2});
    });

    test('signing in with no guest cart leaves the account cart alone', () async {
      repo.server = _state([_item('p1', 'v1', 1)]);
      await cart.startGuestSession();

      await cart.hydrate('uid-1', branchId: 'branch-1');

      expect(_quantities(cart), {'p1': 1});
      expect(repo.syncs, isEmpty);
    });
  });

  group('PostSignIn', () {
    tearDown(PostSignIn.clear);

    test('returns the remembered route once', () {
      PostSignIn.returnTo(AppRoutes.customerCart);
      expect(PostSignIn.take(), AppRoutes.customerCart);
      expect(PostSignIn.take(), isNull);
    });

    test('an abandoned sign-in expires', () {
      PostSignIn.returnTo(AppRoutes.customerCart);
      final later = DateTime.now().add(PostSignIn.maxAge + const Duration(minutes: 1));
      expect(PostSignIn.take(now: later), isNull);
    });

    testWidgets('a customer lands on their cart, with the store behind it', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        initialRoute: '/login',
        routes: {
          '/login': (_) => const Text('login'),
          AppRoutes.customerHome: (_) => const Text('store'),
          AppRoutes.customerCart: (_) => const Text('cart'),
        },
      ));
      PostSignIn.returnTo(AppRoutes.customerCart);
      PostSignIn.go(navigatorKey.currentState!, UserRole.customer);
      await tester.pumpAndSettle();
      expect(find.text('cart'), findsOneWidget);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('store'), findsOneWidget);
      expect(navigatorKey.currentState!.canPop(), isFalse, reason: 'no way back to the sign-in screens');
    });

    testWidgets('staff never get sent to a customer cart', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        initialRoute: '/login',
        routes: {
          '/login': (_) => const Text('login'),
          AppRoutes.homeFor(UserRole.staff): (_) => const Text('staff home'),
          AppRoutes.customerCart: (_) => const Text('cart'),
        },
      ));
      PostSignIn.returnTo(AppRoutes.customerCart);
      PostSignIn.go(navigatorKey.currentState!, UserRole.staff);
      await tester.pumpAndSettle();
      expect(find.text('staff home'), findsOneWidget);
      expect(find.text('cart'), findsNothing);
      expect(PostSignIn.take(), isNull);
    });
  });

  group('storefront search', () {
    final garlic = _product('g', 'gv', name: 'Garlic Peanuts', tags: ['spicy']);

    test('every word must match, in any order and case', () {
      expect(productMatchesSearch(garlic, 'garlic'), isTrue);
      expect(productMatchesSearch(garlic, 'SPICY garlic'), isTrue);
      expect(productMatchesSearch(garlic, 'garlic sweet'), isFalse);
      expect(productMatchesSearch(garlic, '   '), isTrue);
    });
  });

  group('product card', () {
    final product = _product('p1', 'v1', name: 'Adobo Peanuts with a Very Long Name for Wrapping');

    Future<void> pumpCard(WidgetTester tester, {required int quantity, VoidCallback? onAdd, VoidCallback? onDecrease, double scale = 1}) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: productGridDelegate,
            itemCount: 2,
            itemBuilder: (_, i) => ProductCard(
              product: product,
              quantityInCart: quantity,
              onTap: () {},
              onAdd: onAdd ?? () {},
              onDecrease: onDecrease,
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('shows Add when not in the cart', (tester) async {
      var added = 0;
      await pumpCard(tester, quantity: 0, onAdd: () => added++, onDecrease: () {});
      await tester.tap(find.text('Add').first);
      expect(added, 1);
      expect(find.byType(QuantityStepper), findsNothing);
    });

    testWidgets('becomes a − qty + stepper once in the cart', (tester) async {
      var added = 0, removed = 0;
      await pumpCard(tester, quantity: 2, onAdd: () => added++, onDecrease: () => removed++);
      expect(find.byType(QuantityStepper), findsNWidgets(2));
      await tester.tap(find.byTooltip('One more ${product.name}').first);
      await tester.tap(find.byTooltip('One less ${product.name}').first);
      expect(added, 1);
      expect(removed, 1);
    });

    for (final scale in const [1.0, 1.5]) {
      testWidgets('fits a 320 dp phone grid cell at text scale $scale', (tester) async {
        await pumpCard(tester, quantity: 3, onDecrease: () {}, scale: scale);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
