import 'package:flutter/foundation.dart';
import '../../data/catalog_store.dart';
import '../../data/models/branch.dart';
import '../../data/repositories/branch_repository.dart';
import '../../data/repositories/customer_profile_repository.dart';
import '../../data/repositories/products_repository.dart';
import 'customer_data_store.dart';

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

  /// Loads branches (if needed) and restores this customer's saved default
  /// branch (`customer_profiles.default_branch_id`), scoping the catalog to
  /// it. Call once after sign-in, after [CustomerDataStore.profile] is
  /// populated. Safe to call for guests too (leaves [selectedBranch] null).
  Future<void> hydrate() async {
    if (kBranches.isEmpty) {
      await BranchRepository.instance.loadBranches();
    }
    final defaultBranchId = CustomerDataStore.instance.profile?.defaultBranchId;
    if (defaultBranchId == null) {
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
    } catch (_) {
      // Ignore — see above.
    } finally {
      notifyListeners();
    }
  }

  /// Switches the active branch: updates state immediately (optimistic UI),
  /// persists it for signed-in customers, and reloads the catalog scoped to
  /// the new branch's real stock/availability.
  Future<void> selectBranch(Branch branch, {String? firebaseUid}) async {
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
    } catch (_) {
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
    notifyListeners();
  }
}
