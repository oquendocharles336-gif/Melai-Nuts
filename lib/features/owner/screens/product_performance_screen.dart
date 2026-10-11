import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/repositories/staff_repository.dart';

/// Owner-facing, company-wide product ranking by item sales.
///
/// The numbers come from the `owner_sales_summary` RPC, which the database
/// computes from completed orders (the app does no revenue maths of its own).
/// Item sales are quantity x unit price before vouchers and delivery fees, and
/// products are grouped by the name recorded on the order.
///
/// Named [OwnerProductPerformanceScreen] because the Product Management
/// feature exposes `ProductPerformanceScreen`, which simply shows this one.
class OwnerProductPerformanceScreen extends StatefulWidget {
  const OwnerProductPerformanceScreen({super.key});

  @override
  State<OwnerProductPerformanceScreen> createState() => _OwnerProductPerformanceScreenState();
}

class _OwnerProductPerformanceScreenState extends State<OwnerProductPerformanceScreen> {
  static const _periods = [7, 30, 90];
  static final _money = NumberFormat('#,##0.00');

  int _days = 30;
  bool _loading = true;
  Object? _error;
  OwnerSalesSummary? _summary;

  /// Only the latest request may update the screen, so switching periods
  /// quickly can never show an older period's numbers under the new chip.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await StaffRepository.instance.getOwnerSalesSummary(days: _days);
      if (!mounted || id != _requestId) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _selectPeriod(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _summary = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final products = summary?.products ?? const <OwnerProductSales>[];

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Product Performance', showBack: true),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
              child: Row(
                children: [
                  for (final d in _periods)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('$d days'),
                        selected: _days == d,
                        onSelected: (_) => _selectPeriod(d),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: DataStateView(
                  isLoading: _loading,
                  error: _error,
                  isEmpty: products.isEmpty,
                  onRetry: _load,
                  emptyIcon: Icons.leaderboard_outlined,
                  emptyTitle: 'No sales in this period.',
                  emptyMessage: 'Products appear here once there are paid orders.',
                  builder: (context) => _content(summary!),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(OwnerSalesSummary summary) {
    final products = summary.products;
    // Net sales of the whole window (database); the products' net sales add up to it.
    final total = summary.totalWindow;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Row(
            children: [
              Expanded(child: _Stat(label: 'Net sales', value: pesoOrDash(total?.netSales))),
              Expanded(child: _Stat(label: 'Refunds', value: pesoOrDash(total?.refunds))),
              Expanded(child: _Stat(label: 'Products', value: '${products.length}')),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < products.length; i++) ...[
          _RankCard(
            rank: i + 1,
            product: products[i],
            share: total == null || total.netSales <= 0 ? 0 : products[i].revenue / total.netSales,
            money: _money,
          ),
          const SizedBox(height: 10),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Last ${summary.days} days, paid orders. Units = sold − refunded; net sales = item sales − '
            'their share of discounts − refunds of that product (a refund counts on the day it completed). '
            'Delivery fees are not included. Products are matched by the name on the order. Top 50 shown.',
            style: AppTextStyles.bodySm,
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.bodySm),
        Text(value, style: AppTextStyles.titleMd),
      ],
    );
  }
}

class _RankCard extends StatelessWidget {
  final int rank;
  final OwnerProductSales product;
  final double share;
  final NumberFormat money;

  const _RankCard({
    required this.rank,
    required this.product,
    required this.share,
    required this.money,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                child: Text('$rank', style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  product.productName,
                  style: AppTextStyles.labelLg,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '₱${money.format(product.revenue)}',
                style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.border,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${product.units} unit${product.units == 1 ? '' : 's'}'
            '${(product.refundedUnits ?? 0) > 0 ? ' (${product.refundedUnits} refunded)' : ''}'
            ' • ${(share * 100).toStringAsFixed(1)}% of net sales',
            style: AppTextStyles.bodySm,
          ),
        ],
      ),
    );
  }
}
