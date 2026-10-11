import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/staff_models.dart';

/// Staff dashboard. Every number is computed by the database for the branch
/// being worked in and refreshes when orders, stock, transfers or refunds
/// change.
class StaffDashboardTab extends StatelessWidget {
  /// Switches the portal's bottom navigation (1 = Register, 2 = Orders,
  /// 3 = Inventory).
  final ValueChanged<int> onOpenTab;

  const StaffDashboardTab({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final d = store.dashboard;
        return RefreshIndicator(
          onRefresh: store.refreshAll,
          child: DataStateView(
            isLoading: store.dashboardState.busy,
            error: store.dashboardState.error,
            isEmpty: d == null,
            onRetry: store.refreshDashboard,
            emptyIcon: Icons.dashboard_outlined,
            emptyTitle: 'No dashboard data yet.',
            builder: (context) => _content(context, store, d!),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, StaffStore store, StaffDashboard d) {
    final profile = store.profile!;
    final nav = Navigator.of(context);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.roleStaff,
                child: Text(profile.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.fullName.isEmpty ? 'Welcome' : 'Hi, ${profile.fullName.split(' ').first}', style: AppTextStyles.titleMd),
                    Text('${profile.roleLabel} • ${d.branch.name}', style: AppTextStyles.bodySm),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: d.branch.isActive ? AppColors.successBg : AppColors.errorBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  d.branch.isActive ? 'Open' : 'Closed',
                  style: AppTextStyles.labelSm.copyWith(color: d.branch.isActive ? AppColors.success : AppColors.error),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _BigStat(
          label: "TODAY'S NET SALES",
          // net_sales_today missing = older server: unknown ("—"), never its old gross figure.
          value: pesoOrDash(d.netSalesToday),
          footnote: d.netSalesToday == null
              ? 'Net sales need the latest database update • updated ${friendlyTime(d.generatedAt)}'
              : 'Gross ${pesoOrDash(d.grossSalesToday)} − discounts ${pesoOrDash(d.discountsToday)} − refunds '
                  '${pesoOrDash(d.refundsToday)} • updated ${friendlyTime(d.generatedAt)}',
        ),
        const SizedBox(height: 10),
        _grid([
          _Stat('Refunds today', d.refundsToday == null ? '—' : '${pesoOrDash(d.refundsToday)} (${d.refundCountToday ?? 0})',
              Icons.undo_rounded, AppColors.error, () => onOpenTab(2)),
          _Stat('Refund rate today', rateOrDash(d.refundRateToday), Icons.percent_rounded, AppColors.warning, () => onOpenTab(2)),
          _Stat("Today's orders", '${d.ordersToday}', Icons.receipt_long_rounded, AppColors.roleStaff, () => onOpenTab(2)),
          _Stat('Completed today', '${d.completedToday}', Icons.check_circle_outline_rounded, AppColors.success, () => onOpenTab(2)),
          _Stat('Pending', '${d.pendingOrders}', Icons.hourglass_top_rounded, AppColors.warning, () => onOpenTab(2)),
          _Stat('Preparing', '${d.preparingOrders}', Icons.inventory_rounded, AppColors.primary, () => onOpenTab(2)),
          _Stat('Ready / out for delivery', '${d.readyOrders}', Icons.local_shipping_outlined, AppColors.success, () => onOpenTab(2)),
          _Stat('Cancelled today', '${d.cancelledToday}', Icons.cancel_outlined, AppColors.error, () => onOpenTab(2)),
        ]),
        const SizedBox(height: AppSpacing.lg),
        Text('Inventory alerts', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        _grid([
          _Stat('Low stock', '${d.lowStockCount}', Icons.warning_amber_rounded, AppColors.warning,
              () => nav.pushNamed(AppRoutes.inventoryLowStock)),
          _Stat('Out of stock', '${d.outOfStockCount}', Icons.remove_shopping_cart_outlined, AppColors.error,
              () => nav.pushNamed(AppRoutes.inventoryLowStock)),
          _Stat('Expiring within 15 days', '${d.expiringSoonCount}', Icons.schedule_rounded, AppColors.warning,
              () => nav.pushNamed(AppRoutes.inventoryFefo)),
          _Stat('Transfers to approve', '${d.transfersAwaitingApproval}', Icons.outbox_rounded, AppColors.roleStaff,
              () => nav.pushNamed(AppRoutes.inventoryTransfers)),
          _Stat('Transfers arriving', '${d.transfersAwaitingReceipt}', Icons.move_to_inbox_rounded, AppColors.roleStaff,
              () => nav.pushNamed(AppRoutes.inventoryTransfers)),
          if (d.pendingRefunds != null)
            _Stat(
                'Open refund requests (not deducted yet)',
                d.pendingRefundAmount == null ? '${d.pendingRefunds}' : '${d.pendingRefunds} • ${peso(d.pendingRefundAmount!)}',
                Icons.assignment_return_outlined,
                AppColors.error,
                () => nav.pushNamed(AppRoutes.staffRefunds)),
        ]),
        const SizedBox(height: AppSpacing.lg),
        Text('Branch information', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
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
              _InfoLine(Icons.storefront_outlined, d.branch.name),
              if (d.branch.address.isNotEmpty) _InfoLine(Icons.place_outlined, d.branch.address),
              if ((d.branch.contactPhone ?? '').isNotEmpty) _InfoLine(Icons.call_outlined, d.branch.contactPhone!),
              if ((d.branch.operatingHours ?? '').isNotEmpty) _InfoLine(Icons.access_time_rounded, d.branch.operatingHours!),
              _InfoLine(
                Icons.local_shipping_outlined,
                [
                  if (d.branch.supportsPickup) 'Pickup',
                  if (d.branch.supportsDelivery) 'Delivery',
                ].join(' • ').ifEmpty('No pickup or delivery'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _grid(List<_Stat> stats) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.7,
      children: [for (final s in stats) _StatCard(stat: s)],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Stat {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _Stat(this.label, this.value, this.icon, this.color, this.onTap);
}

class _StatCard extends StatelessWidget {
  final _Stat stat;

  const _StatCard({required this.stat});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: stat.onTap,
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(stat.icon, color: stat.color, size: 18),
            const SizedBox(height: 4),
            Text(stat.value, style: AppTextStyles.headlineSm),
            Text(stat.label, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label;
  final String value;
  final String footnote;

  const _BigStat({required this.label, required this.value, required this.footnote});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.labelSm),
          const SizedBox(height: 4),
          Text(value, style: AppTextStyles.headlineLg.copyWith(color: AppColors.primaryDark)),
          const SizedBox(height: 2),
          Text(footnote, style: AppTextStyles.bodySm),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppTextStyles.bodyMd)),
        ],
      ),
    );
  }
}
