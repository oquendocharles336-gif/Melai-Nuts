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
  final int restockThreshold;
  final int batchedQuantity;
  final String? branch;
  final String branchId;
  final List<InventoryBatch> batches;

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
  });

  String get displayName =>
      variantLabel.isEmpty ? productName : '$productName • $variantLabel';

  int get totalStock => quantity;

  int get batchCount => batches.length;

  bool get isOutOfStock => quantity <= 0;

  /// Low but not empty (empty is reported separately as out of stock).
  bool get isLowStock => quantity > 0 && quantity <= restockThreshold;

  bool get needsRestock => quantity <= restockThreshold;

  int get unassignedQuantity => (quantity - batchedQuantity).clamp(0, 999999);

  int get recommendedRestockQty =>
      needsRestock ? (restockThreshold * 2 - quantity).clamp(0, 999999) : 0;

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
