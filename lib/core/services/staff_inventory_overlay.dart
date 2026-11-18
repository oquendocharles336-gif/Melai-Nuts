import '../../data/models/inventory_batch.dart';
import '../../data/models/inventory_item.dart';
import '../../data/repositories/staff_repository.dart';
import 'staff_offline_store.dart';

/// Shows changes made on this device on top of the last server copy of a
/// branch's inventory, without ever overwriting that copy:
///
///  * products created offline appear as items (0 in stock) marked
///    "Pending sync" until the server's inventory contains their variant;
///  * each stock movement made on this device (receive / adjust) is applied
///    as a movement — the quantity shown is the server count plus the
///    movements the server has not counted yet, never an edited stock number.
///
/// Pure function of its inputs, so it is recomputed whenever the server copy
/// or the local records change (that is the reconciliation: once the server
/// copy includes a change, the change is no longer applied on top).
class StaffInventoryOverlay {
  StaffInventoryOverlay._();

  static StaffInventorySnapshot apply({
    required StaffInventorySnapshot base,
    required List<LocalMovement> movements,
    required List<PendingProduct> pendingProducts,
    required String branchName,
  }) {
    if (movements.isEmpty && pendingProducts.every((p) => !p.isCreate)) return base;

    final order = <String>[];
    final items = <String, InventoryItem>{};
    for (final i in base.items) {
      order.add(i.variantId);
      items[i.variantId] = i;
    }

    // Products created on this device that the server copy doesn't have yet.
    for (final p in pendingProducts) {
      if (!p.isCreate || p.variantId.isEmpty || items.containsKey(p.variantId)) continue;
      order.add(p.variantId);
      items[p.variantId] = InventoryItem(
        productId: p.id,
        variantId: p.variantId,
        productName: p.name,
        variantLabel: 'Standard',
        sku: '',
        categoryId: p.categoryId ?? '',
        price: p.price,
        quantity: 0,
        restockThreshold: null,
        batchedQuantity: 0,
        branch: branchName,
        branchId: base.branchId,
        batches: const [],
        isCarried: p.branchIds.contains(base.branchId),
        pendingSync: true,
      );
    }

    for (final m in movements) {
      if (m.branchId != base.branchId) continue;
      final item = items[m.variantId];
      if (item == null) continue; // product no longer visible here
      if (m.isReceive) {
        final batch = InventoryBatch(
          id: 'local:${m.id}',
          productId: m.productId,
          batchCode: m.batchCode ?? '',
          branch: branchName,
          receivedDate: m.receivedDate ?? m.createdAt,
          expirationDate: m.expirationDate ?? m.createdAt,
          quantity: m.quantityChange,
          restockThreshold: m.restockThreshold ?? item.restockThreshold,
          branchId: m.branchId,
          variantId: m.variantId,
          variantLabel: item.variantLabel,
          productName: item.productName,
          pendingSync: true,
        );
        items[m.variantId] = item.copyWith(
          // "Units already counted" only gives existing stock a batch.
          quantity: m.assignExisting ? item.quantity : item.quantity + m.quantityChange,
          batchedQuantity: item.batchedQuantity + m.quantityChange,
          restockThreshold: m.restockThreshold,
          isCarried: true,
          batches: [...item.batches, batch],
          pendingSync: true,
        );
      } else {
        final batches = [
          for (final b in item.batches)
            b.id == m.batchId ? b.copyWith(quantity: b.quantity + m.quantityChange, pendingSync: true) : b,
        ];
        items[m.variantId] = item.copyWith(
          quantity: item.quantity + m.quantityChange,
          batchedQuantity: item.batchedQuantity + m.quantityChange,
          batches: batches,
          pendingSync: true,
        );
      }
    }

    // Each batch carries its variant's branch-wide stock (low-stock checks).
    final result = <InventoryItem>[];
    for (final id in order) {
      final item = items[id]!;
      result.add(item.copyWith(
        batches: [
          for (final b in item.batches)
            b.copyWith(variantStock: item.quantity, restockThreshold: item.restockThreshold),
        ],
      ));
    }
    return StaffInventorySnapshot(
      branchId: base.branchId,
      items: result,
      batches: [for (final i in result) ...i.batches],
    );
  }
}
