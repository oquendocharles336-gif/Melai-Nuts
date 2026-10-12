import 'dart:async';

import '../../data/models/app_user.dart';
import '../../features/customer/cart_controller.dart';
import '../utils/app_error.dart';
import 'branch_controller.dart';
import 'customer_data_store.dart';

/// Outcome of [CustomerSessionBinder.bind]. Binding never throws: a failed
/// step is recorded here (and in the stores' own error state, which drives
/// the customer screens' Retry views) so sign-in / sign-up is never blocked.
class CustomerBindResult {
  /// The Supabase `customer_profiles` row exists and is cached.
  final bool profileReady;

  /// The cart is bound to this customer (it knows their uid). It may still
  /// be waiting for a branch — that is normal for a brand-new account.
  final bool cartReady;

  const CustomerBindResult({required this.profileReady, required this.cartReady});

  bool get isComplete => profileReady && cartReady;
}

typedef BindReporter = void Function(Object error, StackTrace stack, String context);

/// The customer half of a session: what has to happen after the Firebase
/// identity is confirmed and before customer screens are used.
///
///  1. remember who the customer is (so later Retry works even offline),
///  2. create/fetch the Supabase `customer_profiles` row (with their phone),
///  3. bind the cart to this uid and load the customer's records,
///  4. restore the saved default branch.
///
/// Runs on every customer sign-in AND right after a new customer finishes
/// registration — skipping it leaves the cart without a uid, which is what
/// made new accounts see "out of stock" on Add to Cart.
///
/// Each step is isolated: a failed profile step no longer prevents the cart
/// from being bound (previously one try/catch wrapped everything).
class CustomerSessionBinder {
  CustomerSessionBinder({
    required this.remember,
    required this.ensureProfile,
    required this.hydrateCart,
    required this.loadCustomerData,
    required this.hydrateBranch,
    BindReporter? report,
  }) : report = report ?? _defaultReport;

  /// Wired to the real app singletons.
  factory CustomerSessionBinder.live() => CustomerSessionBinder(
        remember: (user) => CustomerDataStore.instance.rememberCustomer(
          firebaseUid: user.uid,
          fallbackName: user.name,
          fallbackEmail: user.email,
          fallbackPhone: user.phone ?? '',
        ),
        ensureProfile: (user) => CustomerDataStore.instance.ensureProfile(
          firebaseUid: user.uid,
          fallbackName: user.name,
          fallbackEmail: user.email,
          fallbackPhone: user.phone ?? '',
        ),
        hydrateCart: (uid) => CartController.instance.hydrate(uid),
        loadCustomerData: (uid) => CustomerDataStore.instance.loadForCustomer(uid),
        hydrateBranch: () => BranchController.instance.hydrate(),
      );

  final void Function(AppUser user) remember;
  final Future<void> Function(AppUser user) ensureProfile;
  final Future<void> Function(String uid) hydrateCart;
  final Future<void> Function(String uid) loadCustomerData;
  final Future<void> Function() hydrateBranch;
  final BindReporter report;

  static void _defaultReport(Object error, StackTrace stack, String context) {
    AppErrors.report(error, stack, context);
  }

  Future<CustomerBindResult> bind(AppUser user) async {
    remember(user);

    var profileReady = true;
    try {
      await ensureProfile(user);
    } catch (e, st) {
      profileReady = false;
      report(e, st, 'customer_session_binder:ensureProfile');
    }

    // Own try blocks: the cart must learn the uid even when the profile step
    // failed, otherwise every Add to Cart fails for a signed-in customer.
    var cartReady = true;
    await Future.wait([
      () async {
        try {
          await hydrateCart(user.uid);
        } catch (e, st) {
          cartReady = false;
          report(e, st, 'customer_session_binder:hydrateCart');
        }
      }(),
      () async {
        try {
          // Never throws by contract; records its own error + Retry state.
          await loadCustomerData(user.uid);
        } catch (e, st) {
          report(e, st, 'customer_session_binder:loadCustomerData');
        }
      }(),
    ]);

    // Needs the profile (loaded above) to restore the saved default branch.
    unawaited(() async {
      try {
        await hydrateBranch();
      } catch (e, st) {
        report(e, st, 'customer_session_binder:hydrateBranch');
      }
    }());

    return CustomerBindResult(profileReady: profileReady, cartReady: cartReady);
  }
}
