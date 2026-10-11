import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/widgets/staff_data_scope.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/inventory_batch.dart';
import '../widgets/fefo_badge.dart';
import '../widgets/stock_status_badge.dart';

/// Full detail for a single batch, including whether it's the "FEFO Next
/// to Sell" batch for its variant at this branch (the one expiring soonest,
/// which is the one the server consumes first).
///
/// The [batch] route argument is only the starting point: the screen always
/// shows the latest copy from the live inventory, so it reflects stock
/// adjustments and sales made while it is open.
class BatchDetailsScreen extends StatelessWidget {
  final InventoryBatch batch;

  const BatchDetailsScreen({super.key, required this.batch});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _content(context, store));
  }

  Widget _content(BuildContext context, StaffStore store) {
    final canManage = store.canManageInventory;
    InventoryBatch? live;
    for (final b in store.batches) {
      if (b.id == this.batch.id) {
        live = b;
        break;
      }
    }

    // The inventory has loaded and this batch is no longer in it (e.g. it
    // was removed or belongs to another branch) — say so instead of showing
    // out-of-date numbers.
    if (live == null && store.inventoryState.loaded) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: const MelaiAppBar(title: 'Batch Details', showBack: true),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'This batch is no longer in the inventory for this branch.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
            ),
          ),
        ),
      );
    }

    final batch = live ?? this.batch;
    final product = findProductById(batch.productId);
    final inventoryItem = store.itemByVariant(batch.variantId);
    final productName = inventoryItem?.productName ?? product.name;

    // FEFO is per variant at the branch, and empty batches are skipped.
    final siblings = store.batches
        .where((b) => b.variantId == batch.variantId && b.quantity > 0)
        .toList()
      ..sort((a, b) => a.expirationDate.compareTo(b.expirationDate));
    final isNextToSell = batch.quantity > 0 && siblings.isNotEmpty && siblings.first.id == batch.id;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Batch Details', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (isNextToSell)
              Container(
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.priority_high_rounded, color: AppColors.primaryDark),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'FEFO NEXT TO SELL — dispatch this batch before newer stock.',
                        style: AppTextStyles.labelLg.copyWith(color: AppColors.primaryDark),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                        child: Icon(product.icon, color: product.color),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(productName, style: AppTextStyles.titleMd),
                            Text('Batch ${batch.batchCode}', style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                      FefoBadge(priority: batch.fefoPriority),
                    ],
                  ),
                  const Divider(height: 28),
                  _DetailRow(label: 'Branch', value: batch.branch),
                  if (batch.variantLabel.isNotEmpty) _DetailRow(label: 'Variant', value: batch.variantLabel),
                  _DetailRow(label: 'Batch Code', value: batch.batchCode),
                  _DetailRow(label: 'Received Date', value: _formatDate(batch.receivedDate)),
                  _DetailRow(label: 'Expiration Date', value: _formatDate(batch.expirationDate)),
                  _DetailRow(
                    label: 'Days Until Expiry',
                    value: batch.daysUntilExpiry < 0 ? 'Expired' : '${batch.daysUntilExpiry} days',
                    valueColor: batch.fefoPriority.color,
                  ),
                  _DetailRow(label: 'Units in this batch', value: '${batch.quantity}'),
                  if (batch.variantStock != null) _DetailRow(label: 'Branch stock (all batches)', value: '${batch.variantStock}'),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Stock Status', style: AppTextStyles.bodySm),
                        StockStatusBadge(isLowStock: batch.isLowStock),
                      ],
                    ),
                  ),
                  if (batch.isLowStock)
                    _DetailRow(
                      label: 'Recommended Restock',
                      value: '+${batch.recommendedRestockQty} packs',
                      valueColor: AppColors.success,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (canManage) ...[
              PrimaryButton(
                label: 'Adjust Stock',
                icon: Icons.tune_rounded,
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.inventoryAdjustment, arguments: batch),
              ),
              const SizedBox(height: 10),
            ],
            SecondaryButton(
              label: 'Stock Transfers',
              icon: Icons.sync_alt_rounded,
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.inventoryTransfers),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodySm),
          Text(value, style: AppTextStyles.labelLg.copyWith(color: valueColor)),
        ],
      ),
    );
  }
}
