import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/owner_sales.dart';
import '../widgets/owner_branch_tile.dart';
import '../widgets/owner_sales_scope.dart';

/// Branch Comparison — branches ranked by the last 7 days of sales, plus each
/// branch's share of revenue. Figures come from the database
/// (`owner_sales_summary`).
///
/// Transaction speed, stock-out incidents and loyalty tap rate are not shown:
/// the backend does not record them yet.
class BranchComparisonScreen extends StatelessWidget {
  const BranchComparisonScreen({super.key});

  static final _money = NumberFormat('#,##0');
  static const _palette = <Color>[
    AppColors.primary,
    AppColors.warning,
    AppColors.success,
    AppColors.darkBrown,
    AppColors.textSecondary,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Branch Comparison', showBack: true),
      body: SafeArea(child: OwnerSalesScope(days: 7, builder: _body)),
    );
  }

  Widget _body(BuildContext context, OwnerSalesSummary summary) {
    if (summary.branches.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.compare_arrows_rounded, size: 64, color: AppColors.textMuted.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text('No comparison data yet.', textAlign: TextAlign.center, style: AppTextStyles.headlineSm.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: 8),
          Text('Add branches to compare their performance.', textAlign: TextAlign.center, style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted)),
        ],
      );
    }

    final ranked = [...summary.branches]..sort((a, b) => b.weekRevenue.compareTo(a.weekRevenue));
    // All branches' net sales for the 7 days, as computed by the database (null: older server).
    final total = summary.totalWeek?.netSales;
    Color colorFor(OwnerBranchSales b) => _palette[summary.branches.indexOf(b) % _palette.length];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('Ranked by net sales over the last 7 days (paid orders − discounts − completed refunds)', style: AppTextStyles.bodySm),
        const SizedBox(height: AppSpacing.lg),
        Text('Branch Comparison Matrix', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < ranked.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OwnerBranchTile(
              sales: ranked[i],
              rank: i + 1,
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchPerformance, arguments: ranked[i].name),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Text('Revenue Share', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
          child: total == null || total <= 0
              ? Text(total == null ? 'Net sales for all branches are not available.' : 'No net sales in the last 7 days.', style: AppTextStyles.bodyMd)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Net Sales Distribution', style: AppTextStyles.labelLg),
                        Text('₱${_money.format(total)} total', style: AppTextStyles.bodySm),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 12,
                        child: Row(
                          children: [
                            for (final b in ranked)
                              if (b.weekRevenue > 0)
                                Expanded(
                                  flex: (b.weekRevenue / total * 1000).round().clamp(1, 1000),
                                  child: Container(color: colorFor(b)),
                                ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        for (final b in ranked)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(width: 10, height: 10, decoration: BoxDecoration(color: colorFor(b), shape: BoxShape.circle)),
                              const SizedBox(width: 4),
                              Text('${b.name} (${(b.weekRevenue / total * 100).toStringAsFixed(0)}%)', style: AppTextStyles.bodySm),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Transaction speed, stock-out incidents and loyalty tap rate are not tracked by the backend yet, so they are not shown.',
          style: AppTextStyles.bodySm,
        ),
      ],
    );
  }
}
