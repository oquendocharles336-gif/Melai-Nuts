import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/models/inventory_batch.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/models/sales_data.dart';
import '../../../data/repositories/staff_repository.dart';
import '../widgets/owner_branch_tile.dart';
import '../widgets/sales_chart.dart';
import '../widgets/stat_card.dart';

/// Owner "Executive Command" dashboard.
///
/// Sales figures come from the database (`owner_sales_summary`, owner-only):
/// net sales (gross − discounts − completed refunds) is the headline, gross,
/// refunds and pending refunds are shown beside it; nothing is added up here.
/// inventory / FEFO figures come from the live [StaffStore] for the branch the
/// owner is currently viewing. Picking a branch chip switches the store to that
/// branch, so the inventory cards always say which branch they describe.
class OwnerDashboardScreen extends StatefulWidget {
  const OwnerDashboardScreen({super.key});

  @override
  State<OwnerDashboardScreen> createState() => _OwnerDashboardScreenState();
}

class _OwnerDashboardScreenState extends State<OwnerDashboardScreen> {
  /// null = all branches.
  String? _branchId;

  bool _loading = true;
  Object? _error;
  OwnerSalesSummary? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await StaffRepository.instance.getOwnerSalesSummary(days: 7);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _selectBranch(String? id) async {
    setState(() => _branchId = id);
    if (id != null) {
      // Inventory and FEFO then describe the branch that was picked.
      await StaffStore.instance.setOwnerBranch(id);
    }
  }

  /// The selected branch's row (null = all branches, or not found).
  OwnerBranchSales? _branch(OwnerSalesSummary s) {
    for (final b in s.branches) {
      if (b.branchId == _branchId) return b;
    }
    return null;
  }

  /// Today's / the last 7 days' figures for the scope on screen, exactly as the
  /// database computed them (all branches: its totals). null = not sent.
  SalesFigures? _today(OwnerSalesSummary s) => _branchId == null ? s.totalToday : _branch(s)?.today;
  SalesFigures? _week(OwnerSalesSummary s) => _branchId == null ? s.totalWeek : _branch(s)?.week;
  double? _pendingRefunds(OwnerSalesSummary s) =>
      _branchId == null ? s.pendingRefunds?.amount : _branch(s)?.pendingRefundAmount;

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _content(context, store));
  }

  Widget _content(BuildContext context, StaffStore store) {
    final inventoryReady = store.inventoryState.loaded;
    final highPriorityBatches =
        store.batches.where((b) => b.fefoPriority == FefoPriority.high).toList();
    final lowStockCount = store.batches.where((b) => b.isLowStock).length;
    final totalInventoryUnits = store.batches.fold<int>(0, (sum, b) => sum + b.quantity);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([_load(), store.refreshInventory()]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('All Branches (${kBranches.length})'),
                      selected: _branchId == null,
                      onSelected: (_) => _selectBranch(null),
                      selectedColor: AppColors.roleOwner.withValues(alpha: 0.15),
                    ),
                  ),
                  for (final b in kBranches)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(b.name),
                        selected: _branchId == b.id,
                        onSelected: (_) => _selectBranch(b.id),
                        selectedColor: AppColors.roleOwner.withValues(alpha: 0.15),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (highPriorityBatches.isNotEmpty)
              InkWell(
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryFefo, arguments: FefoPriority.high),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.errorBg,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: AppColors.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('FEFO Alert: Action Needed', style: AppTextStyles.labelLg.copyWith(color: AppColors.error)),
                            Text(
                              '${highPriorityBatches.length} batch${highPriorityBatches.length == 1 ? '' : 'es'} at ${store.activeBranchName} '
                              'need markdown or a transfer soon.',
                              style: AppTextStyles.bodySm,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.error),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text("Today's Performance", style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            _salesSection(),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Inventory shown for ${store.activeBranchName.isEmpty ? 'the selected branch' : store.activeBranchName}',
              style: AppTextStyles.bodySm,
            ),
            const SizedBox(height: AppSpacing.xs),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
              children: [
                OwnerStatCard(
                  label: 'Orders Count',
                  value: _summary == null || _today(_summary!) == null ? '—' : '${_today(_summary!)!.orders}',
                  sub: 'Paid Orders Today',
                  icon: Icons.receipt_long_outlined,
                  subColor: AppColors.success,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerSalesOverview),
                ),
                OwnerStatCard(
                  label: 'Total Inventory',
                  value: inventoryReady ? '$totalInventoryUnits' : '—',
                  sub: 'Packs in Stock',
                  icon: Icons.inventory_2_outlined,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryDashboard),
                ),
                OwnerStatCard(
                  label: 'Low-Stock Items',
                  value: inventoryReady ? '$lowStockCount SKUs' : '—',
                  sub: 'Reorder Required',
                  icon: Icons.shopping_bag_outlined,
                  valueColor: lowStockCount == 0 ? null : AppColors.error,
                  highlight: lowStockCount > 0,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryLowStock),
                ),
                OwnerStatCard(
                  label: 'Expiring Products',
                  value: inventoryReady ? '${highPriorityBatches.length} Batches' : '—',
                  sub: 'FEFO Priority',
                  icon: Icons.hourglass_bottom_rounded,
                  valueColor: highPriorityBatches.isEmpty ? null : AppColors.error,
                  highlight: highPriorityBatches.isNotEmpty,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryFefo, arguments: FefoPriority.high),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('7-Day Sales Trend', style: AppTextStyles.headlineSm),
                TextButton(
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerSalesTrends),
                  child: const Text('View Trends'),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: _trend(),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Branch Operations', style: AppTextStyles.headlineSm),
                TextButton(
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchComparison),
                  child: const Text('Compare All'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_summary == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    _loading ? 'Loading branch figures…' : 'Branch figures are unavailable right now.',
                    style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
                  ),
                ),
              )
            else if (_summary!.branches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No branches found.', style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted)),
                ),
              )
            else
              for (final b in _summary!.branches)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OwnerBranchTile(
                    sales: b,
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchPerformance, arguments: b.name),
                  ),
                ),
            const SizedBox(height: AppSpacing.sm),
            Text('Quick Links', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.4,
              children: [
                _QuickLink(icon: Icons.dashboard_customize_outlined, label: 'Business Overview', onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerBusinessOverview)),
                _QuickLink(icon: Icons.query_stats_rounded, label: 'Sales Analytics', onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerSalesAnalytics)),
                _QuickLink(icon: Icons.leaderboard_outlined, label: 'Product Performance', onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerProductPerformance)),
                _QuickLink(icon: Icons.local_shipping_outlined, label: 'Delivery Management', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDashboard)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Today's gross sales card, or the loading / error state for it.
  Widget _salesSection() {
    final summary = _summary;
    final decoration = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      border: Border.all(color: AppColors.border),
      boxShadow: AppShadows.sm,
    );

    if (summary == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: decoration,
        child: _loading
            ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _error is AppError ? (_error as AppError).message : 'Could not load sales figures.',
                    style: AppTextStyles.bodyMd,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
      );
    }

    final today = _today(summary);
    final week = _week(summary);
    final pending = _pendingRefunds(summary);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: decoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("TODAY'S NET SALES", style: AppTextStyles.labelSm),
          const SizedBox(height: 4),
          Text(pesoOrDash(today?.netSales), style: AppTextStyles.headlineLg.copyWith(color: AppColors.roleOwner)),
          const SizedBox(height: 6),
          Text(
            'Gross ${pesoOrDash(today?.grossSales)} • Refunds ${pesoOrDash(today?.refunds)}'
            '${today == null ? '' : ' (${today.refundCount})'} • Refund rate ${rateOrDash(today?.refundRate)}',
            style: AppTextStyles.bodySm,
          ),
          if (pending != null && pending > 0)
            Text('${peso(pending)} in refunds pending (not deducted yet)', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          const SizedBox(height: 8),
          Text(
            week == null
                ? 'Last 7 days: —'
                : 'Last 7 days: ${peso(week.netSales)} net from ${week.orders} paid order${week.orders == 1 ? '' : 's'}',
            style: AppTextStyles.bodySm,
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text('Could not refresh — showing the last loaded figures.', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          ],
        ],
      ),
    );
  }

  /// Company-wide revenue for the last 7 days (the database returns this
  /// series for all branches together).
  Widget _trend() {
    final summary = _summary;
    if (summary == null) {
      return SizedBox(
        height: 200,
        child: Center(child: Text(_loading ? 'Loading…' : 'Trend unavailable right now.')),
      );
    }
    if (summary.daily.every((d) => d.revenue == 0)) {
      return const SizedBox(height: 200, child: Center(child: Text('No sales in the last 7 days.')));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('All branches • net sales (a refund counts on the day it completed)', style: AppTextStyles.bodySm),
        const SizedBox(height: 8),
        SalesBarChart(
          points: [for (final d in summary.daily) RevenuePoint(DateFormat('E').format(d.date), d.revenue)],
        ),
      ],
    );
  }
}

class _QuickLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickLink({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.roleOwner, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: AppTextStyles.labelMd, maxLines: 2)),
          ],
        ),
      ),
    );
  }
}
