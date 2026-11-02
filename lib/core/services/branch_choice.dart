import '../../data/models/branch.dart';
import '../../data/models/order.dart';
import '../utils/geo_utils.dart';

/// Why the app set this branch; checkout tells the customer.
enum BranchChoiceReason { nearest, lastOrder, savedBranch, onlyBranch }

class BranchChoice {
  final Branch branch;
  final BranchChoiceReason reason;

  /// Straight-line distance from the customer, when [reason] is nearest.
  final double? distanceKm;

  const BranchChoice(this.branch, this.reason, {this.distanceKm});
}

/// The branch only changes when the new one is at least this much closer, so
/// someone halfway between two branches doesn't have their cart moved back and
/// forth by GPS drift.
const double kBranchSwitchMarginKm = 1.0;

/// Straight-line distance to [branch], or null without a position or map pin.
double? distanceToBranch(double? latitude, double? longitude, Branch branch) {
  final lat = branch.latitude, lng = branch.longitude;
  if (latitude == null || longitude == null || !GeoUtils.isValidPin(lat, lng)) return null;
  return GeoUtils.distanceKm(latitude, longitude, lat!, lng!);
}

/// The closest open branch that has a map pin, or null when there is none.
Branch? nearestOpenBranch(double latitude, double longitude, Iterable<Branch> branches) {
  Branch? nearest;
  var nearestKm = double.infinity;
  for (final branch in branches) {
    if (!branch.isOpenForPickup) continue;
    final km = distanceToBranch(latitude, longitude, branch);
    if (km != null && km < nearestKm) {
      nearest = branch;
      nearestKm = km;
    }
  }
  return nearest;
}

/// The branch of the customer's newest order that was not cancelled.
String? lastOrderBranchId(Iterable<Order> orders) {
  Order? newest;
  for (final order in orders) {
    if (order.status == OrderStatus.cancelled || order.branchId == null) continue;
    if (newest == null || order.date.isAfter(newest.date)) newest = order;
  }
  return newest?.branchId;
}

/// Decides the branch: the nearest open one, then (without a location) the only
/// open one, the last order's, or the saved one. Null means nothing can be set
/// until the customer turns location on. Only open branches are ever chosen.
///
/// [currentBranch] is where the customer is now: it is kept unless the nearest
/// branch is at least [kBranchSwitchMarginKm] closer.
BranchChoice? chooseBranch({
  required Iterable<Branch> branches,
  double? latitude,
  double? longitude,
  String? lastOrderBranch,
  String? savedBranch,
  String? currentBranch,
}) {
  Branch? openById(String? id) {
    for (final branch in branches) {
      if (branch.id == id && branch.isOpenForPickup) return branch;
    }
    return null;
  }

  if (latitude != null && longitude != null) {
    final nearest = nearestOpenBranch(latitude, longitude, branches);
    if (nearest != null) {
      final nearestKm = distanceToBranch(latitude, longitude, nearest)!;
      final current = openById(currentBranch);
      final currentKm = current == null ? null : distanceToBranch(latitude, longitude, current);
      if (current != null && currentKm != null && currentKm - nearestKm < kBranchSwitchMarginKm) {
        return BranchChoice(current, BranchChoiceReason.nearest, distanceKm: currentKm);
      }
      return BranchChoice(nearest, BranchChoiceReason.nearest, distanceKm: nearestKm);
    }
  }
  final open = branches.where((b) => b.isOpenForPickup).toList();
  if (open.length == 1) return BranchChoice(open.single, BranchChoiceReason.onlyBranch);
  final fromLastOrder = openById(lastOrderBranch);
  if (fromLastOrder != null) return BranchChoice(fromLastOrder, BranchChoiceReason.lastOrder);
  final saved = openById(savedBranch);
  if (saved != null) return BranchChoice(saved, BranchChoiceReason.savedBranch);
  return null;
}

/// One cart line, as far as stock is concerned.
class CartNeed {
  final String variantId;
  final String name;
  final int quantity;

  const CartNeed({required this.variantId, required this.name, required this.quantity});
}

/// A cart line a branch cannot fill. [available] is 0 when it has none or does
/// not sell it.
class StockShortfall {
  final String name;
  final int needed;
  final int available;

  const StockShortfall({required this.name, required this.needed, required this.available});
}

/// Units on the shelf: branch id -> variant id -> quantity. A branch that does
/// not sell a variant has no entry for it.
typedef BranchStock = Map<String, Map<String, int>>;

List<StockShortfall> shortfallsAt(String branchId, Iterable<CartNeed> needs, BranchStock stock) {
  final shelf = stock[branchId] ?? const <String, int>{};
  return [
    for (final need in needs)
      if ((shelf[need.variantId] ?? 0) < need.quantity)
        StockShortfall(name: need.name, needed: need.quantity, available: shelf[need.variantId] ?? 0),
  ];
}

/// The answer of moving the cart to a branch.
class CartMoveResult {
  final bool isMoved;

  /// Lines lowered or removed because the new branch has fewer of them.
  final List<StockShortfall> shortfalls;

  /// The voucher or points no longer apply to the moved cart, so they were dropped.
  final bool droppedDiscounts;

  /// Customer-ready reason when the cart could not move.
  final String? message;

  const CartMoveResult.moved({this.shortfalls = const [], this.droppedDiscounts = false})
      : isMoved = true,
        message = null;
  const CartMoveResult.failed(this.message)
      : isMoved = false,
        shortfalls = const [],
        droppedDiscounts = false;

  bool get cartChanged => shortfalls.isNotEmpty || droppedDiscounts;
}

/// What the customer must be told after a move changed their cart.
class CartMoveNotice {
  final String branchName;
  final List<StockShortfall> shortfalls;
  final bool droppedDiscounts;

  const CartMoveNotice({required this.branchName, required this.shortfalls, required this.droppedDiscounts});
}

/// How the branch reaches the customer's cart, which lives in the feature layer.
class BranchCartLink {
  final Future<CartMoveResult> Function(String branchId) move;
  final String? Function() branchId;

  const BranchCartLink({required this.move, required this.branchId});
}
