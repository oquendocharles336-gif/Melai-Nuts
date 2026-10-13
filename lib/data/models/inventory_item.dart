import 'inventory_batch.dart';

/// One sellable variant (e.g. "Garlic Peanuts — 100g") at one branch, with
/// its real stock, restock level and the batches that make it up.
///
/// [quantity] is the branch's authoritative stock count (`branch_inventory`,
/// which is also what customers and the register are checked against);
/// [batches] are the FEFO batches recorded for it. [unassignedQuantity] is
/// stock that is counted but not yet assigned to a batch.
class InventoryItem {
  final String productId;
  final String variantId;
  final String productName;
  final String variantLabel;
  final String sku;
  final String categoryId;
  final double price;
  final int quantity;
  /// Restock level: the item's own threshold, else the owner's fallback
  /// (business settings); null = Not set (only "out of stock" is flagged).
  final int? restockThreshold;
  final int batchedQuantity;
  final String? branch;
  final String branchId;
  final List<InventoryBatch> batches;

  /// Whether this branch sells the item (`branch_inventory.is_carried`). An
  /// item the branch doesn't carry is "not sold here", never "out of stock",
  /// and is left out of the low / out-of-stock counts. Receiving stock for it
  /// makes it carried.
  final bool isCarried;

  const InventoryItem({
    required this.productId,
    required this.variantId,
    required this.productName,
    required this.variantLabel,
    required this.sku,
    required this.categoryId,
    required this.price,
    required this.quantity,
    required this.restockThreshold,
    required this.batchedQuantity,
    required this.branchId,
    required this.batches,
    this.branch,
    this.isCarried = true,
  });

  String get displayName =>
      variantLabel.isEmpty ? productName : '$productName • $variantLabel';

  int get totalStock => quantity;

  int get batchCount => batches.length;

  /// The branch doesn't sell this item (shown as "Not sold here").
  bool get isNotSoldHere => !isCarried;

  /// Nothing on the shelf: can't be sold at the register right now (out of
  /// stock, or not sold here).
  bool get hasNoStock => quantity <= 0;

  /// Sold here and empty. Items the branch doesn't sell are not "out of stock".
  bool get isOutOfStock => isCarried && quantity <= 0;

  /// Low but not empty (empty is reported separately as out of stock).
  /// Never true while no restock level is set.
  bool get isLowStock {
    final t = restockThreshold;
    return isCarried && t != null && quantity > 0 && quantity <= t;
  }

  /// Out of stock, or at / below its restock level.
  bool get needsRestock => isOutOfStock || isLowStock;

  int get unassignedQuantity => (quantity - batchedQuantity).clamp(0, 999999);

  /// Units below the restock level (0 when above it or when no level is set).
  /// Purely derived from real numbers; no reorder rule is invented here (the
  /// demand-based suggestion is `staff_reorder_suggestions` in the database).
  int get unitsBelowRestockLevel {
    final t = restockThreshold;
    return t == null ? 0 : (t - quantity).clamp(0, 999999);
  }

  /// The most urgent FEFO tier among this item's batches (HIGH beats
  /// MEDIUM beats LOW), used to badge the item in list screens.
  FefoPriority get worstFefoPriority {
    if (batches.isEmpty) return FefoPriority.low;
    return batches.map((b) => b.fefoPriority).reduce(
          (a, b) => a.index < b.index ? a : b,
        );
  }

  /// Batches sorted soonest-to-expire first — index 0 is sold next (FEFO).
  List<InventoryBatch> get batchesFefoSorted {
    final list = List<InventoryBatch>.from(batches);
    list.sort((a, b) => a.expirationDate.compareTo(b.expirationDate));
    return list;
  }

  InventoryBatch? get nextToSellBatch =>
      batchesFefoSorted.isEmpty ? null : batchesFefoSorted.first;
}
