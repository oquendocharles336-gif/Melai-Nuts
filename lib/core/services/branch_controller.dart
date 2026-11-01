import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import '../../data/catalog_store.dart';
import '../../data/models/branch.dart';
import '../../data/repositories/branch_repository.dart';
import '../../data/repositories/customer_profile_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../utils/geo_utils.dart';
import 'auth_service.dart';
import 'customer_data_store.dart';
import 'device_location.dart';
import '../utils/app_error.dart';

/// The customer's currently selected branch, app-wide.
///
/// This is the piece that makes branch selection actually *do* something:
/// when [selectBranch] is called, it persists the choice (for signed-in
/// customers, to `customer_profiles.default_branch_id`) and re-scopes the
/// shared product catalog (`kProducts`) to that branch's real stock via
/// [ProductsRepository.loadCatalog], then notifies listeners so every
/// screen watching this controller (Home, Cart, Checkout) redraws with the
/// new branch's info and availability.
class BranchController extends ChangeNotifier {
  BranchController._();
  static final BranchController instance = BranchController._();

  Branch? _selectedBranch;
  Branch? get selectedBranch => _selectedBranch;

  bool _switching = false;
  bool get isSwitching => _switching;

  bool _locating = false;

  /// True while [autoSelectNearest] is reading the location.
  bool get isLocating => _locating;

  bool _autoSelected = false;

  /// True when [selectedBranch] was picked from the device's location.
  bool get isAutoSelected => _autoSelected;

  // Only once per app launch; a branch picked by hand stays until the next one.
  bool _autoAttempted = false;
  bool _chosenByHand = false;

  /// The closest branch to a position that serves customers and has map
  /// coordinates, or null when no branch has them.
  static Branch? nearestBranch(double latitude, double longitude, Iterable<Branch> branches) {
    Branch? nearest;
    var nearestKm = double.infinity;
    for (final branch in branches) {
      final lat = branch.latitude, lng = branch.longitude;
      if (!branch.servesCustomers || !GeoUtils.isValidPin(lat, lng)) continue;
      final km = GeoUtils.distanceKm(latitude, longitude, lat!, lng!);
      if (km < nearestKm) {
        nearest = branch;
        nearestKm = km;
      }
    }
    return nearest;
  }

  /// Selects the branch nearest to the device, so customers need not choose.
  /// When the location cannot be read (or no branch has coordinates) nothing
  /// changes and the customer can still choose by hand.
  Future<void> autoSelectNearest() async {
    if (_autoAttempted || _chosenByHand) return;
    _autoAttempted = true;
    _locating = true;
    notifyListeners();
    try {
      if (kBranches.isEmpty) await BranchRepository.instance.loadBranches();
      // Don't ask for the location when it could not be used.
      if (nearestBranch(0, 0, kBranches) == null) return;
      final position = await DeviceLocation.current(
        timeout: const Duration(seconds: 10),
        accuracy: LocationAccuracy.low,
      );
      if (!position.ok || _chosenByHand) return;
      final branch = nearestBranch(position.latitude!, position.longitude!, kBranches);
      if (branch == null) return;
      _autoSelected = true;
      if (branch.id != _selectedBranch?.id) {
        await selectBranch(
          branch,
          firebaseUid: AuthService.instance.currentFirebaseUser?.uid,
          byHand: false,
        );
      }
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'branch_controller:auto');
    } finally {
      _locating = false;
      notifyListeners();
    }
  }

  /// Loads branches (if needed) and restores this customer's saved default
  /// branch (`customer_profiles.default_branch_id`), scoping the catalog to
  /// it. Call once after sign-in, after [CustomerDataStore.profile] is
  /// populated. Safe to call for guests too (leaves [selectedBranch] null).
  Future<void> hydrate() async {
    if (kBranches.isEmpty) {
      await BranchRepository.instance.loadBranches();
    }
    final defaultBranchId = CustomerDataStore.instance.profile?.defaultBranchId;
    // The location or the customer already decided: the saved one must not undo that.
    if (defaultBranchId == null || _autoSelected || _chosenByHand) {
      notifyListeners();
      return;
    }
    final branch = BranchRepository.instance.findById(defaultBranchId);
    if (branch == null) {
      notifyListeners();
      return;
    }
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

  /// Switches the active branch: updates state immediately (optimistic UI),
  /// persists it for signed-in customers, and reloads the catalog scoped to
  /// the new branch's real stock/availability.
  Future<void> selectBranch(Branch branch, {String? firebaseUid, bool byHand = true}) async {
    if (byHand) {
      _chosenByHand = true;
      _autoSelected = false;
    }
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

  /// Clears the in-memory selection on sign-out. The persisted preference in
  /// Supabase is untouched, so it's restored on the next [hydrate].
  void clear() {
    _selectedBranch = null;
    _autoSelected = false;
    _autoAttempted = false;
    _chosenByHand = false;
    notifyListeners();
  }
}
