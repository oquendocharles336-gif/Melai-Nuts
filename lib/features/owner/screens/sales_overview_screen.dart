import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/owner_sales.dart';
import '../widgets/owner_sales_scope.dart';

/// Sales Overview — Today / Last 7 Days / Last 30 Days totals with a
/// per-branch breakdown. Every figure is computed by the database
/// (`owner_sales_summary`); "30 days" is a rolling window, not a calendar month.
/// Net sales (gross − discounts − completed refunds) is the headline; gross,
/// refunds, refund rate and pending refunds are shown beside it.
class SalesOverviewScreen extends StatefulWidget {
  const SalesOverviewScreen({super.key});

  @override
  State<SalesOverviewScreen> createState() => _SalesOverviewScreenState();
}

enum _Period { today, week, month }

class _SalesOverviewScreenState extends State<SalesOverviewScreen> {
  static final _money = NumberFormat('#,##0.00');

  _Period _period = _Period.today;

  double _revenue(OwnerBranchSales b) => switch (_period) {
        _Period.today => b.todayRevenue,
        _Period.week => b.weekRevenue,
        _Period.month => b.windowRevenue,
      };

  SalesFigures? _branchFigures(OwnerBranchSales b) => switch (_period) {
        _Period.today => b.today,
        _Period.week => b.week,
        _Period.month => b.window,
      };

  /// All branches together, as computed by the database (null: older server).
  SalesFigures? _total(OwnerSalesSummary s) => switch (_period) {
        _Period.today => s.totalToday,
        _Period.week => s.totalWeek,
        _Period.month => s.totalWindow,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Sales Overview',
        showBack: true,
        actions: [
          IconButton(tooltip: 'Sales analytics', icon: const Icon(Icons.query_stats_rounded), onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerSalesAnalytics)),
        ],
      ),
      body: SafeArea(
        child: OwnerSalesScope(days: 30, builder: _body),
      ),
    );
  }

  Widget _body(BuildContext context, OwnerSalesSummary summary) {
    final branches = summary.branches;
    final total = _total(summary);
    final pending = summary.pendingRefunds;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        SegmentedButton<_Period>(
          segments: const [
            ButtonSegment(value: _Period.today, label: Text('Today')),
            ButtonSegment(value: _Period.week, label: Text('7 Days')),
            ButtonSegment(value: _Period.month, label: Text('30 Days')),
          ],
          selected: {_period},
          onSelectionChanged: (s) => setState(() => _period = s.first),
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NET SALES', style: AppTextStyles.labelSm),
              Text(pesoOrDash(total?.netSales), style: AppTextStyles.headlineLg.copyWith(color: AppColors.roleOwner)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _Figure(label: 'Gross sales', value: pesoOrDash(total?.grossSales))),
                  Expanded(child: _Figure(label: 'Discounts', value: pesoOrDash(total?.discounts))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _Figure(
                      label: 'Refunds${total == null ? '' : ' (${total.refundCount})'}',
                      value: pesoOrDash(total?.refunds),
                      color: (total?.refunds ?? 0) > 0 ? AppColors.error : null,
                    ),
                  ),
                  Expanded(child: _Figure(label: 'Refund rate', value: rateOrDash(total?.refundRate))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _Figure(label: 'Paid orders', value: total == null ? '—' : '${total.orders}')),
                  Expanded(child: _Figure(label: 'Avg order value', value: pesoOrDash(total?.averageOrderValue))),
                ],
              ),
              if (pending != null && pending.count > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${pending.count} refund${pending.count == 1 ? '' : 's'} pending (${peso(pending.amount)}), not deducted yet',
                  style: AppTextStyles.bodySm.copyWith(color: AppColors.warning),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Per-Branch Breakdown', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
          child: branches.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text('No branches found.', style: AppTextStyles.bodyMd),
                )
              : Column(
                  children: [
                    for (var i = 0; i < branches.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(branches[i].name, style: AppTextStyles.bodyMd),
                                  if (_branchFigures(branches[i]) != null)
                                    Text(
                                      'Gross ${peso(_branchFigures(branches[i])!.grossSales)} • '
                                      'refunds ${peso(_branchFigures(branches[i])!.refunds)}',
                                      style: AppTextStyles.bodySm,
                                    ),
                                ],
                              ),
                            ),
                            Text('₱${_money.format(_revenue(branches[i]))}', style: AppTextStyles.labelLg),
                          ],
                        ),
                      ),
                      if (i != branches.length - 1) const Divider(height: 1),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Net sales = paid orders − discounts − completed refunds (delivery fees not included). '
          'A refund counts on the day it was completed; refunds still being reviewed are not deducted. '
          'Days are Asia/Manila days. The admin website shows the same figures.',
          style: AppTextStyles.bodySm,
        ),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerSalesTrends),
          icon: const Icon(Icons.show_chart_rounded, size: 16),
          label: const Text('Trends'),
        ),
      ],
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
        Text(label, style: AppTextStyles.bodySm),
        Text(value, style: AppTextStyles.titleMd.copyWith(color: color)),
      ],
    );
  }
}
