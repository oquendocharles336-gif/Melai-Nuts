import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/inventory_batch.dart';
import '../widgets/inventory_card.dart';

/// Shared dashboard content — used both as the Staff Portal's "Inventory"
/// tab body and wrapped in [InventoryDashboardScreen] for direct/deep-link
/// navigation. All numbers come from the branch's real inventory.
class InventoryDashboardBody extends StatelessWidget {
  const InventoryDashboardBody({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) => RefreshIndicator(
        onRefresh: store.refreshInventory,
        child: DataStateView(
          isLoading: store.inventoryState.busy,
          error: store.inventoryState.error,
          isEmpty: store.inventoryItems.isEmpty,
          onRetry: store.refreshInventory,
          emptyIcon: Icons.inventory_2_outlined,
          emptyTitle: 'No products yet.',
          emptyMessage: 'Products added to the catalog will appear here.',
          builder: (context) => _content(context, store),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, StaffStore store) {
    final items = store.inventoryItems;
    final lowItems = items.where((i) => i.needsRestock).toList()
      ..sort((a, b) => a.quantity.compareTo(b.quantity));
    final expiringSoonCount =
        store.batches.where((b) => b.fefoPriority == FefoPriority.high).length;
    final totalUnits = items.fold<int>(0, (sum, i) => sum + i.quantity);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Total SKUs',
                value: '${items.length}',
                icon: Icons.inventory_2_outlined,
                color: AppColors.roleStaff,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: 'Total Units',
                value: '$totalUnits',
                icon: Icons.widgets_outlined,
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Low / Out of Stock',
                value: '${lowItems.length}',
                icon: Icons.warning_amber_rounded,
                color: AppColors.error,
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryLowStock),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: 'Expiring Soon',
                value: '$expiringSoonCount',
                icon: Icons.schedule_rounded,
                color: AppColors.warning,
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryFefo),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Quick Actions', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            _ActionTile(
              icon: Icons.timeline_rounded,
              label: 'FEFO Overview',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryFefo),
            ),
            _ActionTile(
              icon: Icons.list_alt_rounded,
              label: 'Inventory List',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryList),
            ),
            _ActionTile(
              icon: Icons.storefront_outlined,
              label: 'Branch Inventory',
              onTap: () => Navigator.of(context).pushNamed(
                AppRoutes.inventoryBranch,
                arguments: store.activeBranchName,
              ),
            ),
            _ActionTile(
              icon: Icons.sync_alt_rounded,
              label: 'Stock Transfers',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryTransfers),
            ),
            if (store.canManageInventory)
              _ActionTile(
                icon: Icons.add_box_outlined,
                label: 'Add Inventory',
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryAdd),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Low Stock Alerts', style: AppTextStyles.headlineSm),
            TextButton(
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.inventoryLowStock),
              child: const Text('View all'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        if (lowItems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing is low on stock right now.', style: AppTextStyles.bodyMd),
          )
        else
          for (final item in lowItems.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InventoryCard.item(
                item: item,
                onTap: () => Navigator.of(context)
                    .pushNamed(AppRoutes.inventoryProductDetails, arguments: item.variantId),
              ),
            ),
      ],
    );
  }
}

/// Standalone, directly-navigable version of the dashboard (wraps the
/// shared body in its own Scaffold + app bar).
class InventoryDashboardScreen extends StatelessWidget {
  const InventoryDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Inventory Dashboard', showBack: true),
      body: SafeArea(child: InventoryDashboardBody()),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Text(value, style: AppTextStyles.headlineSm),
            Text(label, style: AppTextStyles.bodySm),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.roleStaff),
            const Spacer(),
            Text(label, style: AppTextStyles.labelLg),
          ],
        ),
      ),
    );
  }
}
