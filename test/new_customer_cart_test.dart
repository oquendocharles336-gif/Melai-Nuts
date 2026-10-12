import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/customer_session_binder.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/app_user.dart';
import 'package:melai_nuts/data/models/customer_profile.dart';
import 'package:melai_nuts/data/models/product.dart';
import 'package:melai_nuts/data/models/user_role.dart';
import 'package:melai_nuts/data/repositories/customer_profile_repository.dart';
import 'package:melai_nuts/features/customer/cart_controller.dart';
import 'package:melai_nuts/features/customer/widgets/product_card.dart';

Product _product({int stock = 5, bool active = true}) => Product.fromRow(
      {'id': 'p1', 'name': 'Garlic Peanuts', 'price': 100, 'category_id': 'c', 'is_active': active},
      variantRows: const [
        {'id': 'v1', 'label': '100g', 'price': 100},
      ],
      stockByVariantId: {'v1': stock},
      branchAvailability: const [],
      totalStock: stock,
    );

const _newCustomer = AppUser(
  uid: 'uid-new',
  email: 'new@example.com',
  name: 'New Customer',
  role: UserRole.customer,
  phone: '+639171234567',
  isActive: true,
);

/// Records what the binder did, standing in for the real stores.
class _FakeSession {
  String? rememberedUid;
  AppUser? profileCreatedFor;
  CustomerProfile? profile;
  String? cartUid;
  String? dataLoadedFor;
  bool branchHydrated = false;
  final List<String> reported = [];

  CustomerSessionBinder binder({bool profileFails = false}) => CustomerSessionBinder(
        remember: (u) => rememberedUid = u.uid,
        ensureProfile: (u) async {
          profileCreatedFor = u;
          if (profileFails) throw Exception('offline');
          // Mirrors CustomerProfileRepository.ensureProfile's insert.
          final row = CustomerProfileRepository.newProfileRow(
            firebaseUid: u.uid,
            fullName: u.name,
            email: u.email,
            phone: u.phone ?? '',
          );
          profile = CustomerProfile.fromRow(row);
        },
        hydrateCart: (uid) async => cartUid = uid,
        loadCustomerData: (uid) async => dataLoadedFor = uid,
        hydrateBranch: () async => branchHydrated = true,
        report: (e, st, ctx) => reported.add(ctx),
      );
}

void main() {
  group('customer bind after registration', () {
    test('binds the cart and creates the profile for a new customer', () async {
      final fake = _FakeSession();
      final result = await fake.binder().bind(_newCustomer);
      await Future<void>.delayed(Duration.zero); // let the branch step run

      expect(result.isComplete, isTrue);
      expect(fake.rememberedUid, 'uid-new');
      expect(fake.cartUid, 'uid-new', reason: 'cart must know the uid or every add fails');
      expect(fake.profile, isNotNull);
      expect(fake.dataLoadedFor, 'uid-new');
      expect(fake.branchHydrated, isTrue);
    });

    test('a failed profile step still binds the cart', () async {
      final fake = _FakeSession();
      final result = await fake.binder(profileFails: true).bind(_newCustomer);

      expect(result.profileReady, isFalse);
      expect(result.cartReady, isTrue);
      expect(fake.cartUid, 'uid-new');
      expect(fake.reported, contains('customer_session_binder:ensureProfile'));
    });
  });

  group('registration phone reaches customer_profiles', () {
    test('the bind passes the phone to the profile step', () async {
      final fake = _FakeSession();
      await fake.binder().bind(_newCustomer);
      expect(fake.profileCreatedFor?.phone, '+639171234567');
      expect(fake.profile?.phone, '+639171234567');
    });

    test('the inserted row includes the phone, and omits an empty one', () {
      final withPhone = CustomerProfileRepository.newProfileRow(
        firebaseUid: 'u', fullName: 'A', email: 'a@x.com', phone: ' +639171234567 ');
      expect(withPhone['phone'], '+639171234567');

      final without = CustomerProfileRepository.newProfileRow(firebaseUid: 'u', fullName: 'A', email: 'a@x.com');
      expect(without.containsKey('phone'), isFalse);
    });

    test('an existing profile without a phone gets backfilled', () {
      const empty = CustomerProfile(firebaseUid: 'u', fullName: 'A', email: '', phone: '');
      const filled = CustomerProfile(firebaseUid: 'u', fullName: 'A', email: '', phone: '+639170000000');
      expect(CustomerProfileRepository.shouldBackfillPhone(empty, '+639171234567'), isTrue);
      expect(CustomerProfileRepository.shouldBackfillPhone(filled, '+639171234567'), isFalse);
      expect(CustomerProfileRepository.shouldBackfillPhone(empty, ''), isFalse);
    });
  });

  group('add to cart reports the real reason', () {
    final cart = CartController.instance;
    tearDown(() => cart.debugBind(null));

    test('not signed in is not "out of stock"', () async {
      cart.debugBind(null);
      final p = _product();
      final direct = cart.addProduct(p, p.variants.first);
      final live = await cart.addProductWithLiveCheck(p, p.variants.first);
      for (final r in [direct, live]) {
        expect(r.ok, isFalse);
        expect(r.failure, AddToCartFailure.notSignedIn);
        expect(r.message, isNot(contains('out of stock')));
      }
    });

    test('signed in without a branch asks for a branch', () async {
      cart.debugBind('uid-new');
      final p = _product();
      final direct = cart.addProduct(p, p.variants.first);
      final live = await cart.addProductWithLiveCheck(p, p.variants.first);
      for (final r in [direct, live]) {
        expect(r.failure, AddToCartFailure.noBranch);
        expect(r.message, 'Please select a branch first.');
      }
    });

    test('out of stock only when stock is really 0', () {
      cart.debugBind('uid-new', branchId: 'b1');
      final p = _product(stock: 0);
      final r = cart.addProduct(p, p.variants.first, stockOverride: 0);
      expect(r.failure, AddToCartFailure.outOfStock);
      expect(r.message, contains('out of stock'));
    });

    test('an inactive product is "no longer available"', () async {
      cart.debugBind('uid-new', branchId: 'b1');
      final p = _product(active: false);
      final r = await cart.addProductWithLiveCheck(p, p.variants.first);
      expect(r.failure, AddToCartFailure.unavailable);
    });

    test('only the out-of-stock reason says "out of stock"', () {
      for (final f in AddToCartFailure.values) {
        final says = AddToCartResult.messageFor(f).toLowerCase().contains('out of stock');
        expect(says, f == AddToCartFailure.outOfStock, reason: f.name);
      }
    });

    test('a stale error is cleared at the start of an add', () async {
      cart.debugBind(null);
      cart.lastError = 'Please sign in before adding items to your cart.';
      final p = _product();
      await cart.addProductWithLiveCheck(p, p.variants.first);
      expect(cart.lastError, isNull);
    });
  });

  group('server stock messages map to stock wording', () {
    AppError map(String raw) => AppErrors.from(Exception(raw), scope: ErrorScope.order);

    test('"Only N of X left at this branch."', () {
      expect(map('Only 2 of Garlic Peanuts left at this branch.').kind, AppErrorKind.insufficientStock);
    });
    test('"The requested quantity is not available at this branch."', () {
      expect(map('The requested quantity is not available at this branch.').kind, AppErrorKind.insufficientStock);
    });
    test('"X is not available at this branch." is about the item, not the branch', () {
      expect(map('Garlic Peanuts is not available at this branch.').kind, AppErrorKind.productUnavailable);
    });
    test('a closed branch is still a branch problem', () {
      expect(map('This branch is closed right now.').kind, AppErrorKind.branchUnavailable);
    });
  });

  group('stock label before a branch is chosen', () {
    test('says to choose a branch instead of "In Stock"', () {
      final chip = CustomerStockChip.of(_product(stock: 8), branchChosen: false);
      expect(chip.label, CustomerStockChip.chooseBranchLabel);
    });
    test('zero everywhere is still out of stock', () {
      expect(CustomerStockChip.of(_product(stock: 0), branchChosen: false).label, 'Out of Stock');
    });
    test('with a branch, the real label', () {
      final chip = CustomerStockChip.of(_product(stock: 8), branchChosen: true);
      expect(chip.label, 'In Stock');
      expect(chip.worthShowing, isFalse);
    });
  });
}
