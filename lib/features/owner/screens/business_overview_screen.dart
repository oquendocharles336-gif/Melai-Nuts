import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/models/product.dart';
import '../widgets/owner_sales_scope.dart';
import '../widgets/stat_card.dart';

/// "All Branches" business overview — consolidated sales across every branch
/// (from the database) plus catalog margin by category. Margins come from the
/// cost and price recorded in the product catalog; they are not sales margins.
class BusinessOverviewScreen extends StatelessWidget {
  const BusinessOverviewScreen({super.key});

  static final _money = NumberFormat('#,##0');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Business Overview', showBack: true),
      body: SafeArea(
        child: OwnerSalesScope(days: 30, builder: _body),
      ),
    );
  }

  Widget _body(BuildContext context, OwnerSalesSummary summary) {
    final branches = summary.branches;
    // All branches together, computed by the database (null on an older server: "—").
    final month = summary.totalWindow;
    final week = summary.totalWeek;
    final avgMargin = kProducts.isEmpty
        ? null
        : kProducts.map((p) => p.marginPercent).reduce((a, b) => a + b) / kProducts.length;

    // Catalog margin per category.
    final byCategory = <String, List<Product>>{};
    for (final p in kProducts) {
      byCategory.putIfAbsent(p.categoryId, () => []).add(p);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          '${branches.length} branch${branches.length == 1 ? '' : 'es'} • net sales: paid orders − discounts − completed refunds',
          style: AppTextStyles.bodySm,
        ),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
          children: [
            OwnerStatCard(
              label: 'Last 30 Days (Net)',
              value: pesoWholeOrDash(month?.netSales),
              sub: 'Refunds ${pesoWholeOrDash(month?.refunds)} • ${rateOrDash(month?.refundRate)}',
              icon: Icons.payments_outlined,
            ),
            OwnerStatCard(
              label: 'Last 7 Days (Net)',
              value: pesoWholeOrDash(week?.netSales),
              sub: 'Gross ${pesoWholeOrDash(week?.grossSales)}',
              icon: Icons.calendar_view_week_rounded,
            ),
            OwnerStatCard(label: 'Orders (7 Days)', value: week == null ? '—' : '${week.orders}', sub: 'Paid orders', icon: Icons.receipt_long_outlined),
            OwnerStatCard(
              label: 'Avg. Catalog Margin',
              value: avgMargin == null ? '—' : '${avgMargin.toStringAsFixed(1)}%',
              icon: Icons.trending_up_rounded,
              valueColor: AppColors.success,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Branch Breakdown', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
          child: branches.isEmpty
              ? Padding(padding: const EdgeInsets.all(14), child: Text('No branches found.', style: AppTextStyles.bodyMd))
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
                                  Text(branches[i].name, style: AppTextStyles.labelLg),
                                  Text('${branches[i].ordersWeek} orders in 7 days', style: AppTextStyles.bodySm),
                                ],
                              ),
                            ),
                            Text('₱${_money.format(branches[i].weekRevenue)}', style: AppTextStyles.titleMd.copyWith(color: AppColors.primary)),
                          ],
                        ),
                      ),
                      if (i != branches.length - 1) const Divider(height: 1),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Catalog Margin by Category', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        if (byCategory.isEmpty)
          Text('No products in the catalog yet.', style: AppTextStyles.bodyMd)
        else
          for (final entry in byCategory.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _CategoryRow(categoryId: entry.key, products: entry.value),
            ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchComparison),
                icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                label: const Text('Compare Branches'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.productManagement),
                icon: const Icon(Icons.sell_outlined, size: 16),
                label: const Text('Pricing Hub'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String categoryId;
  final List<Product> products;

  const _CategoryRow({required this.categoryId, required this.products});

  @override
  Widget build(BuildContext context) {
    final category = findCategoryById(categoryId);
    final margin = products.map((p) => p.marginPercent).reduce((a, b) => a + b) / products.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(category.icon, size: 18, color: category.color),
              const SizedBox(width: 8),
              Expanded(child: Text(category.name, style: AppTextStyles.labelLg)),
              Text('Margin ${margin.toStringAsFixed(1)}%', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${products.length} product${products.length == 1 ? '' : 's'}', style: AppTextStyles.bodySm),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: (margin / 100).clamp(0.0, 1.0), minHeight: 6, backgroundColor: AppColors.border, color: category.color),
          ),
        ],
      ),
    );
  }
}
