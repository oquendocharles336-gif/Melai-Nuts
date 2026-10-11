import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/catalog_store.dart';
import '../widgets/inventory_card.dart';

/// Full inventory detail for one variant (e.g. "Garlic Peanuts • 100g"):
/// branch stock, restock level and every active batch in FEFO order.
class InventoryProductDetailsScreen extends StatelessWidget {
  final String variantId;

  const InventoryProductDetailsScreen({super.key, required this.variantId});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final item = store.itemByVariant(variantId);
        if (item == null) {
          return Scaffold(
            backgroundColor: AppColors.canvas,
            appBar: const MelaiAppBar(title: 'Inventory', showBack: true),
            body: Center(
              child: store.inventoryState.busy
                  ? const CircularProgressIndicator()
                  : Text('This product is no longer in the inventory.', style: AppTextStyles.bodyMd),
            ),
          );
        }
        final product = findProductById(item.productId);
        final batches = item.batchesFefoSorted;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: MelaiAppBar(title: item.productName, showBack: true),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.sm,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: product.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(product.icon, color: product.color, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.displayName, style: AppTextStyles.titleMd),
                            if (item.sku.isNotEmpty) Text('SKU ${item.sku}', style: AppTextStyles.bodySm),
                            Text('Restock at ${item.restockThreshold} or fewer', style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${item.quantity}',
                            style: AppTextStyles.headlineSm
                                .copyWith(color: item.needsRestock ? AppColors.error : AppColors.roleStaff),
                          ),
                          Text('units in stock', style: AppTextStyles.labelSm),
                        ],
                      ),
                    ],
                  ),
                ),
                if (item.unassignedQuantity > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.warningBg,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, color: AppColors.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${item.unassignedQuantity} unit(s) are counted in stock but not assigned to a batch, '
                            'so they have no expiry date yet.',
                            style: AppTextStyles.bodySm,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Active Batches (FEFO order)', style: AppTextStyles.headlineSm),
                    Text('${batches.length} batches', style: AppTextStyles.bodySm),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                for (int i = 0; i < batches.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InventoryCard.batch(
                      batch: batches[i],
                      nextToSell: i == 0,
                      onTap: () => Navigator.of(context)
                          .pushNamed(AppRoutes.inventoryBatchDetails, arguments: batches[i]),
                    ),
                  ),
                if (batches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('No batches recorded for this product.', style: AppTextStyles.bodyMd)),
                  ),
                const SizedBox(height: AppSpacing.md),
                if (store.canManageInventory) ...[
                  PrimaryButton(
                    label: 'Receive Stock / New Batch',
                    icon: Icons.add_box_outlined,
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.inventoryReceive, arguments: item),
                  ),
                  if (batches.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SecondaryButton(
                      label: 'Adjust Stock',
                      icon: Icons.tune_rounded,
                      onPressed: () => Navigator.of(context)
                          .pushNamed(AppRoutes.inventoryAdjustment, arguments: batches.first),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
