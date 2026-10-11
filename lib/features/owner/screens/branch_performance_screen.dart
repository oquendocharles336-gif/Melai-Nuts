import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/models/branch.dart';
import '../../../data/models/inventory_batch.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/repositories/staff_repository.dart';
import '../widgets/stat_card.dart';

/// Deep-dive into one branch: its details, real sales figures from the
/// database (`owner_sales_summary`) and its current inventory / FEFO status.
///
/// Opening the screen points the owner's live inventory at this branch, so the
/// stock figures below always describe the branch in the title.
class BranchPerformanceScreen extends StatefulWidget {
  final String branch;

  const BranchPerformanceScreen({super.key, required this.branch});

  @override
  State<BranchPerformanceScreen> createState() => _BranchPerformanceScreenState();
}

class _BranchPerformanceScreenState extends State<BranchPerformanceScreen> {
  static final _money = NumberFormat('#,##0.00');

  bool _loading = true;
  Object? _error;
  OwnerBranchSales? _sales;

  Branch? get _branch {
    for (final b in kBranches) {
      if (b.name == widget.branch) return b;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final branch = _branch;
    if (branch != null) {
      StaffStore.instance.setOwnerBranch(branch.id);
    }
    _load();
  }

  Future<void> _load() async {
    final branch = _branch;
    if (branch == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await StaffRepository.instance.getOwnerSalesSummary(days: 7);
      if (!mounted) return;
      OwnerBranchSales? match;
      for (final s in summary.branches) {
        if (s.branchId == branch.id) match = s;
      }
      setState(() {
        _sales = match;
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

  @override
  Widget build(BuildContext context) {
    final branch = _branch;
    if (branch == null) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: MelaiAppBar(title: widget.branch, showBack: true),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('This branch could not be found.', textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
            ),
          ),
        ),
      );
    }

    return StaffDataScope(builder: (context, store) => _content(context, store, branch));
  }

  Widget _content(BuildContext context, StaffStore store, Branch branch) {
    final sales = _sales;
    final inventoryForThisBranch = store.activeBranchId == branch.id && store.inventoryState.loaded;
    final lowStock = store.batches.where((b) => b.isLowStock).length;
    final highPriority = store.batches.where((b) => b.fefoPriority == FefoPriority.high).length;
    final today = sales?.today;
    final week = sales?.week;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: branch.name, showBack: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.wait([_load(), store.refreshInventory()]);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: AppColors.roleOwner.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.storefront_rounded, color: AppColors.roleOwner),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(branch.address.isEmpty ? 'No address on file' : branch.address, style: AppTextStyles.labelLg),
                          if ((branch.contactPhone ?? '').isNotEmpty) Text(branch.contactPhone!, style: AppTextStyles.bodySm),
                          if ((branch.operatingHours ?? '').isNotEmpty) Text(branch.operatingHours!, style: AppTextStyles.bodySm),
                          Text(branch.isActive ? 'Open for orders' : 'Temporarily closed', style: AppTextStyles.bodySm),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Sales', style: AppTextStyles.headlineSm),
              const SizedBox(height: AppSpacing.sm),
              if (sales == null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                  child: _loading
                      ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error is AppError ? (_error as AppError).message : 'Sales figures are unavailable for this branch.',
                              style: AppTextStyles.bodyMd,
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(onPressed: _load, child: const Text('Retry')),
                          ],
                        ),
                )
              else
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.6,
                  children: [
                    OwnerStatCard(
                      label: "Today's Net Sales",
                      value: '₱${_money.format(sales.todayRevenue)}',
                      sub: 'Gross ${pesoOrDash(today?.grossSales)}',
                      icon: Icons.payments_outlined,
                    ),
                    OwnerStatCard(
                      label: 'Refunds Today',
                      value: pesoOrDash(today?.refunds),
                      sub: 'Rate ${rateOrDash(today?.refundRate)}',
                      icon: Icons.undo_rounded,
                    ),
                    OwnerStatCard(label: 'Orders Today', value: '${sales.ordersToday}', sub: 'Avg ${pesoOrDash(today?.averageOrderValue)}', icon: Icons.receipt_long_outlined),
                    OwnerStatCard(
                      label: 'Pending Refunds',
                      value: pesoOrDash(sales.pendingRefundAmount),
                      sub: sales.pendingRefundCount == null ? 'Not deducted yet' : '${sales.pendingRefundCount} open • not deducted',
                      icon: Icons.hourglass_top_rounded,
                    ),
                    OwnerStatCard(
                      label: 'Last 7 Days (Net)',
                      value: '₱${_money.format(sales.weekRevenue)}',
                      sub: 'Refunds ${pesoOrDash(week?.refunds)}',
                      icon: Icons.calendar_view_week_rounded,
                    ),
                    OwnerStatCard(label: 'Orders (7 Days)', value: '${sales.ordersWeek}', sub: 'Paid orders', icon: Icons.shopping_bag_outlined),
                  ],
                ),
              const SizedBox(height: AppSpacing.lg),
              Text('Inventory & FEFO Status', style: AppTextStyles.headlineSm),
              const SizedBox(height: AppSpacing.sm),
              if (!inventoryForThisBranch)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                  child: store.inventoryState.error != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Could not load this branch\'s inventory.', style: AppTextStyles.bodyMd),
                            const SizedBox(height: 8),
                            OutlinedButton(onPressed: store.refreshInventory, child: const Text('Retry')),
                          ],
                        )
                      : const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OwnerStatCard(
                        label: 'Low Stock',
                        value: '$lowStock SKUs',
                        icon: Icons.warning_amber_rounded,
                        highlight: lowStock > 0,
                        valueColor: lowStock > 0 ? AppColors.error : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OwnerStatCard(
                        label: 'Expiring Soon',
                        value: '$highPriority Batches',
                        icon: Icons.hourglass_bottom_rounded,
                        highlight: highPriority > 0,
                        valueColor: highPriority > 0 ? AppColors.error : null,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
