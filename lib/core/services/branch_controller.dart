import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import '../../data/catalog_store.dart';
import '../../data/models/branch.dart';
import '../../data/repositories/branch_repository.dart';
import '../../data/repositories/customer_profile_repository.dart';
import '../../data/repositories/products_repository.dart';
import 'auth_service.dart';
import 'branch_choice.dart';
import 'customer_data_store.dart';
import 'device_location.dart';
import '../utils/app_error.dart';

/// The customer's branch, app-wide. Customers never pick it: [refreshBranch]
/// sets it from the phone's location, and with no location from their last
/// order. Setting it saves it to `customer_profiles.default_branch_id` and
/// re-scopes the shared product catalog (`kProducts`) to that branch's stock.
class BranchController extends ChangeNotifier {
  BranchController._();
  static final BranchController instance = BranchController._();

  Branch? _selectedBranch;
  Branch? get selectedBranch => _selectedBranch;

  bool _switching = false;
  bool get isSwitching => _switching;

  bool _locating = false;

  /// True while [refreshBranch] is working: the order can't be placed yet.
  bool get isLocating => _locating;

  BranchChoice? _choice;

  /// Why [selectedBranch] is the branch; null until it has been worked out.
  BranchChoice? get choice => _choice;

  /// True when [selectedBranch] was picked from the device's location.
  bool get isAutoSelected => _choice?.reason == BranchChoiceReason.nearest;

  bool _locationOff = false;

  /// True when the last try could not read the location: ask to turn it on.
  bool get locationOff => _locationOff;

  /// Set while an order is being placed: the branch must not change under it.
  bool pauseRefresh = false;

  CartMoveNotice? _moveNotice;

  /// Hands over the notice about a move that changed the cart, once.
  CartMoveNotice? takeMoveNotice() {
    final notice = _moveNotice;
    _moveNotice = null;
    return notice;
  }

  bool get hasMoveNotice => _moveNotice != null;

  /// The closest open branch to a position that has map coordinates, or null
  /// when no branch has them.
  static Branch? nearestBranch(double latitude, double longitude, Iterable<Branch> branches) =>
      nearestOpenBranch(latitude, longitude, branches);

  // The system prompt shows once per launch, not on every return to the app.
  // The position stays in memory only.
  bool _askedForLocation = false;
  BranchCartLink? _cartLink;
  Future<void>? _refreshing;
  bool _refreshAgain = false;

  /// Sets the branch from the location, moving the cart to it. Safe to call at
  /// any time: only one runs at a time, and a call made during one runs once
  /// more afterwards.
  Future<void> refreshBranch({BranchCartLink? cart}) {
    if (cart != null) _cartLink = cart;
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      return running;
    }
    final future = _refreshLoop();
    _refreshing = future;
    return future;
  }

  Future<void> _refreshLoop() async {
    try {
      do {
        _refreshAgain = false;
        await _refreshOnce();
      } while (_refreshAgain);
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _refreshOnce() async {
    if (pauseRefresh) return;
    _locating = true;
    notifyListeners();
    try {
      if (kBranches.isEmpty) await BranchRepository.instance.loadBranches();
      final position = await DeviceLocation.current(
        timeout: const Duration(seconds: 10),
        accuracy: LocationAccuracy.low,
        askPermission: !_askedForLocation,
      );
      _askedForLocation = true;
      _locationOff = !position.ok;
      if (pauseRefresh) return;

      final cart = _cartLink;
      final store = CustomerDataStore.instance;
      final choice = chooseBranch(
        branches: kBranches,
        latitude: position.latitude,
        longitude: position.longitude,
        lastOrderBranch: lastOrderBranchId(store.orders),
        savedBranch: store.profile?.defaultBranchId,
        currentBranch: cart?.branchId() ?? _selectedBranch?.id,
      );
      if (choice == null) {
        _choice = null;
        if (_selectedBranch?.isOpenForPickup != true) _selectedBranch = null;
        return;
      }

      if (cart != null) {
        final move = await cart.move(choice.branch.id);
        if (!move.isMoved) {
          await _stayOnCartBranch(cart);
          return;
        }
        if (move.cartChanged) {
          _moveNotice = CartMoveNotice(
            branchName: choice.branch.name,
            shortfalls: move.shortfalls,
            droppedDiscounts: move.droppedDiscounts,
          );
        }
      }
      _choice = choice;
      if (choice.branch.id != _selectedBranch?.id) await selectBranch(choice.branch);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'branch_controller:refresh');
    } finally {
      _locating = false;
      notifyListeners();
    }
  }

  /// The cart could not move: keep showing the branch it is really at, so the
  /// order goes to the branch on screen. The next refresh tries again.
  Future<void> _stayOnCartBranch(BranchCartLink cart) async {
    final id = cart.branchId();
    final matches = kBranches.where((b) => b.id == id);
    if (matches.isEmpty) return;
    final branch = matches.first;
    _choice = BranchChoice(branch, BranchChoiceReason.savedBranch);
    if (branch.id != _selectedBranch?.id) await selectBranch(branch);
  }

  /// Loads branches (if needed) and restores the saved branch until the
  /// location answers. Call once after sign-in, after the customer's profile
  /// and orders have loaded. Safe for guests too.
  Future<void> hydrate() async {
    if (kBranches.isEmpty) {
      await BranchRepository.instance.loadBranches();
    }
    final defaultBranchId = CustomerDataStore.instance.profile?.defaultBranchId;
    final branch = defaultBranchId == null || _choice != null
        ? null
        : BranchRepository.instance.findById(defaultBranchId);
    if (branch == null) {
      notifyListeners();
    } else {
      _selectedBranch = branch;
      notifyListeners();
      // Best-effort: scope the already-loaded catalog to this branch. If it
      // fails, the aggregate (all-branches) view loaded at boot stays in
      // place rather than showing an empty catalog.
      try {
        await ProductsRepository.instance.loadCatalog(branchId: branch.id);
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'branch_controller:53');
        // Ignore — see above.
      } finally {
        notifyListeners();
      }
    }
    // The customer's orders are in now: a refresh that started without them
    // may have found no branch to use.
    if (_cartLink != null) await refreshBranch();
  }

  /// Sets the branch: updates state immediately, saves it for signed-in
  /// customers, and reloads the catalog scoped to the new branch's real stock.
  Future<void> selectBranch(Branch branch) async {
    final firebaseUid = AuthService.instance.currentFirebaseUser?.uid;
    _selectedBranch = branch;
    _switching = true;
    notifyListeners();
    try {
      final tasks = <Future<void>>[
        ProductsRepository.instance.loadCatalog(branchId: branch.id),
      ];
      if (firebaseUid != null) {
        tasks.add(
          CustomerProfileRepository.instance.setDefaultBranch(firebaseUid, branch.id),
        );
      }
      await Future.wait(tasks);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'branch_controller:77');
      // Selection still applies locally for this session even if the
      // catalog reload or the persisted-preference save failed offline.
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// Clears the in-memory selection on sign-out. The saved branch in Supabase
  /// is untouched, so it's restored on the next [hydrate].
  void clear() {
    _selectedBranch = null;
    _choice = null;
    _locationOff = false;
    _askedForLocation = false;
    _moveNotice = null;
    _refreshAgain = false;
    pauseRefresh = false;
    notifyListeners();
  }
}
