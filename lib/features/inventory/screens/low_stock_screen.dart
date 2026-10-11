import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';

/// Products at or below their restock level (including out of stock), each
/// with a restock recommendation. "Restock" opens the receive-stock form for
/// that product.
class LowStockScreen extends StatelessWidget {
  const LowStockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final items = store.inventoryItems.where((i) => i.needsRestock).toList()
          ..sort((a, b) => a.quantity.compareTo(b.quantity));
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: const MelaiAppBar(title: 'Low Stock & Restock', showBack: true),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshInventory,
              child: DataStateView(
                isLoading: store.inventoryState.busy,
                error: store.inventoryState.error,
                isEmpty: items.isEmpty,
                onRetry: store.refreshInventory,
                emptyIcon: Icons.check_circle_outline_rounded,
                emptyTitle: 'Everything is well stocked.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final product = findProductById(item.productId);
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                        border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
                        boxShadow: AppShadows.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(product.icon, color: product.color, size: 20),
                              const SizedBox(width: 8),
                              Expanded(child: Text(item.displayName, style: AppTextStyles.labelLg)),
                              if (item.isOutOfStock)
                                Text('OUT OF STOCK', style: AppTextStyles.labelSm.copyWith(color: AppColors.error)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Current: ${item.quantity} / Restock level: ${item.restockThreshold}',
                                style: AppTextStyles.bodySm,
                              ),
                              Text(
                                'Suggested: +${item.recommendedRestockQty}',
                                style: AppTextStyles.labelLg.copyWith(color: AppColors.success),
                              ),
                            ],
                          ),
                          if (store.canManageInventory) ...[
                            const SizedBox(height: 10),
                            PrimaryButton(
                              label: 'Restock +${item.recommendedRestockQty}',
                              icon: Icons.add_circle_outline_rounded,
                              onPressed: () => Navigator.of(context)
                                  .pushNamed(AppRoutes.inventoryReceive, arguments: item),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
