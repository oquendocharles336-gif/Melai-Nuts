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
import '../widgets/stat_card.dart';

/// Sales Analytics — last-30-day totals (net sales, gross, refunds, refund
/// rate) and the top products by net item sales (units net of refunded units),
/// all computed by the database (`owner_sales_summary`).
///
/// Revenue by category and the payment-method mix are not shown here (they are
/// on the admin website's Reports page); the app does not estimate them.
class SalesAnalyticsScreen extends StatelessWidget {
  const SalesAnalyticsScreen({super.key});

  static final _money = NumberFormat('#,##0.00');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Sales Analytics', showBack: true),
      body: SafeArea(
        child: OwnerSalesScope(days: 30, builder: _body),
      ),
    );
  }

  Widget _body(BuildContext context, OwnerSalesSummary summary) {
    final total = summary.totalWindow;
    final pending = summary.pendingRefunds;
    final top = summary.products.take(5).toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('Last 30 days', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
          children: [
            OwnerStatCard(label: 'Net Sales', value: pesoOrDash(total?.netSales), sub: 'After discounts and refunds', icon: Icons.payments_outlined),
            OwnerStatCard(label: 'Gross Sales', value: pesoOrDash(total?.grossSales), sub: 'Discounts ${pesoOrDash(total?.discounts)}', icon: Icons.point_of_sale_outlined),
            OwnerStatCard(
              label: 'Refunds',
              value: pesoOrDash(total?.refunds),
              sub: 'Rate ${rateOrDash(total?.refundRate)}${total == null ? '' : ' • ${total.refundCount} completed'}',
              icon: Icons.undo_rounded,
            ),
            OwnerStatCard(
              label: 'Pending Refunds',
              value: pesoOrDash(pending?.amount),
              sub: pending == null ? 'Not deducted yet' : '${pending.count} open • not deducted yet',
              icon: Icons.hourglass_top_rounded,
            ),
            OwnerStatCard(label: 'Orders', value: total == null ? '—' : '${total.orders}', sub: 'Paid', icon: Icons.receipt_long_outlined),
            OwnerStatCard(label: 'Avg Order Value', value: pesoOrDash(total?.averageOrderValue), icon: Icons.shopping_bag_outlined),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Top Products by Net Sales', style: AppTextStyles.headlineSm),
            TextButton(
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerProductPerformance),
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (top.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('No sales in the last 30 days.')),
          )
        else
          for (final p in top)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                child: Row(
                  children: [
                    Expanded(child: Text(p.productName, style: AppTextStyles.bodyMd, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(
                      '${p.units} sold${(p.refundedUnits ?? 0) > 0 ? ' (${p.refundedUnits} refunded)' : ''}',
                      style: AppTextStyles.bodySm,
                    ),
                    const SizedBox(width: 10),
                    Text('₱${_money.format(p.revenue)}', style: AppTextStyles.labelLg.copyWith(color: AppColors.primary)),
                  ],
                ),
              ),
            ),
        const SizedBox(height: AppSpacing.lg),
        const _UnavailableCard(
          title: 'Revenue by Category',
          message: 'Sales by category (net of refunds) are on the Reports page of the admin website.',
        ),
        const SizedBox(height: AppSpacing.sm),
        const _UnavailableCard(
          title: 'Payment Method Mix',
          message: 'Net sales by payment method are on the Reports page of the admin website.',
        ),
      ],
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  final String title;
  final String message;

  const _UnavailableCard({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.labelLg),
          const SizedBox(height: 4),
          Text('Not in the app yet. $message', style: AppTextStyles.bodySm),
        ],
      ),
    );
  }
}
