import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../widgets/inventory_card.dart';

/// Inventory for the branch being worked in — every variant stocked there.
class BranchInventoryScreen extends StatelessWidget {
  final String branch;

  const BranchInventoryScreen({super.key, required this.branch});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final items = store.inventoryItems;
        final totalUnits = items.fold<int>(0, (sum, i) => sum + i.quantity);
        final lowCount = items.where((i) => i.needsRestock).length;
        final title = store.activeBranchName.isEmpty ? branch : store.activeBranchName;

        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: MelaiAppBar(title: title, showBack: true),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshInventory,
              child: DataStateView(
                isLoading: store.inventoryState.busy,
                error: store.inventoryState.error,
                isEmpty: items.isEmpty,
                onRetry: store.refreshInventory,
                emptyIcon: Icons.storefront_outlined,
                emptyTitle: 'No inventory recorded for this branch.',
                builder: (context) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _Figure(label: 'PRODUCTS', value: '${items.length}'),
                          _Figure(label: 'TOTAL UNITS', value: '$totalUnits'),
                          _Figure(label: 'LOW / OUT', value: '$lowCount', color: AppColors.error),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text('Products at this branch', style: AppTextStyles.headlineSm),
                    const SizedBox(height: AppSpacing.sm),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InventoryCard.item(
                          item: item,
                          onTap: () => Navigator.of(context)
                              .pushNamed(AppRoutes.inventoryProductDetails, arguments: item.variantId),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Figure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.labelSm),
        Text(value, style: AppTextStyles.headlineSm.copyWith(color: color)),
      ],
    );
  }
}
