import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/inventory_batch.dart';
import '../../../data/models/inventory_item.dart';
import 'fefo_badge.dart';

/// A single tappable row summarizing either a whole [InventoryItem]
/// (aggregated product view — used on list/branch screens) or a single
/// [InventoryBatch] (used on FEFO/low-stock/batch-list screens).
///
/// Use [InventoryCard.item] or [InventoryCard.batch] rather than the
/// default constructor.
class InventoryCard extends StatelessWidget {
  final String productId;
  final String title;
  final String subtitle;
  final int quantity;
  final FefoPriority priority;
  final bool isLowStock;
  final bool nextToSell;
  final VoidCallback onTap;

  const InventoryCard._({
    required this.productId,
    required this.title,
    required this.subtitle,
    required this.quantity,
    required this.priority,
    required this.isLowStock,
    required this.onTap,
    this.nextToSell = false,
  });

  factory InventoryCard.item({required InventoryItem item, required VoidCallback onTap}) {
    final batches = '${item.batchCount} batch${item.batchCount == 1 ? '' : 'es'}';
    final unassigned = item.unassignedQuantity > 0 ? ' • ${item.unassignedQuantity} not in a batch' : '';
    return InventoryCard._(
      productId: item.productId,
      title: item.displayName,
      subtitle: item.isOutOfStock ? 'Out of stock' : '$batches$unassigned',
      quantity: item.totalStock,
      priority: item.worstFefoPriority,
      isLowStock: item.needsRestock,
      onTap: onTap,
    );
  }

  factory InventoryCard.batch({
    required InventoryBatch batch,
    required VoidCallback onTap,
    bool nextToSell = false,
  }) {
    final product = findProductById(batch.productId);
    return InventoryCard._(
      productId: batch.productId,
      title: batch.variantLabel.isEmpty ? product.name : '${product.name} • ${batch.variantLabel}',
      subtitle: 'Batch ${batch.batchCode} • ${batch.daysUntilExpiry < 0 ? 'expired' : '${batch.daysUntilExpiry}d left'}',
      quantity: batch.quantity,
      priority: batch.fefoPriority,
      isLowStock: batch.isLowStock,
      onTap: onTap,
      nextToSell: nextToSell,
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = findProductById(productId);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: isLowStock ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(product.icon, color: product.color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(title, style: AppTextStyles.labelLg, overflow: TextOverflow.ellipsis)),
                      if (nextToSell) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(20)),
                          child: Text('NEXT TO SELL', style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
                        ),
                      ],
                    ],
                  ),
                  Text(subtitle, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$quantity', style: AppTextStyles.titleMd.copyWith(color: isLowStock ? AppColors.error : null)),
                FefoBadge(priority: priority),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
