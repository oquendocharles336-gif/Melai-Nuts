import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../widgets/inventory_card.dart';

/// Every product variant stocked at the branch, with real quantities. Tap
/// through to see the batches (FEFO order) that make up the stock.
class InventoryListScreen extends StatelessWidget {
  const InventoryListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final items = store.inventoryItems;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: MelaiAppBar(
            title: store.activeBranchName.isEmpty ? 'Inventory List' : 'Inventory • ${store.activeBranchName}',
            showBack: true,
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshInventory,
              child: DataStateView(
                isLoading: store.inventoryState.busy,
                error: store.inventoryState.error,
                isEmpty: items.isEmpty,
                onRetry: store.refreshInventory,
                emptyIcon: Icons.inventory_2_outlined,
                emptyTitle: 'No products yet.',
                emptyMessage: 'Products added to the catalog will appear here.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return InventoryCard.item(
                      item: item,
                      onTap: () => Navigator.of(context)
                          .pushNamed(AppRoutes.inventoryProductDetails, arguments: item.variantId),
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
