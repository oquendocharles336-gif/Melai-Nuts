import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/models/sales_data.dart';
import '../widgets/owner_sales_scope.dart';
import '../widgets/sales_chart.dart';

/// Sales Trends — daily, weekly (7-day) and 30-day net sales with the change
/// from the previous period, and the refunds deducted in each period.
///
/// The database returns one net-sales total per day (`owner_sales_summary`:
/// gross − discounts − refunds completed that day) and the day's refunds;
/// this screen only groups those daily totals into consecutive 7- or 30-day
/// periods ending today. Orders per period are not reported, so they are not
/// shown.
class SalesTrendsScreen extends StatefulWidget {
  const SalesTrendsScreen({super.key});

  @override
  State<SalesTrendsScreen> createState() => _SalesTrendsScreenState();
}

enum _Granularity { daily, weekly, monthly }

class _Bucket {
  final DateTime first;
  final DateTime last;
  final double revenue;
  final int days;

  /// Refunds completed in the period (null when the server does not send them).
  final double? refunds;

  const _Bucket(this.first, this.last, this.revenue, this.days, this.refunds);
}

class _SalesTrendsScreenState extends State<SalesTrendsScreen> {
  static final _money = NumberFormat('#,##0');
  static final _day = DateFormat('MMM d');

  _Granularity _granularity = _Granularity.weekly;

  int get _size => switch (_granularity) {
        _Granularity.daily => 1,
        _Granularity.weekly => 7,
        _Granularity.monthly => 30,
      };

  int get _count => switch (_granularity) {
        _Granularity.daily => 14,
        _Granularity.weekly => 4,
        _Granularity.monthly => 6,
      };

  /// Consecutive [size]-day periods ending with the most recent day, newest
  /// first. One extra period is returned so the oldest shown one has a
  /// previous period to compare with.
  List<_Bucket> _buckets(List<OwnerDailySales> daily) {
    final out = <_Bucket>[];
    for (var i = 0; i < _count + 1; i++) {
      final end = daily.length - i * _size;
      final start = end - _size;
      if (start < 0) break;
      final slice = daily.sublist(start, end);
      final refunds = slice.any((d) => d.figures == null) ? null : slice.fold<double>(0, (s, d) => s + d.figures!.refunds);
      out.add(_Bucket(slice.first.date, slice.last.date, slice.fold<double>(0, (s, d) => s + d.revenue), _size, refunds));
    }
    return out;
  }

  double? _growth(List<_Bucket> buckets, int i) {
    if (i + 1 >= buckets.length) return null;
    final previous = buckets[i + 1].revenue;
    if (previous <= 0) return null;
    return (buckets[i].revenue - previous) / previous * 100;
  }

  String _label(_Bucket b, int i) => switch (_granularity) {
        _Granularity.daily => DateFormat('E').format(b.last),
        _Granularity.weekly => 'W${i + 1}',
        _Granularity.monthly => 'P${i + 1}',
      };

  String _range(_Bucket b) => b.days == 1 ? _day.format(b.last) : '${_day.format(b.first)} – ${_day.format(b.last)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Sales Trends', showBack: true),
      // 240 days covers six 30-day periods plus one to compare the oldest with.
      body: SafeArea(child: OwnerSalesScope(days: 240, builder: _body)),
    );
  }

  Widget _body(BuildContext context, OwnerSalesSummary summary) {
    final buckets = _buckets(summary.daily);
    final shown = buckets.take(_count).toList();
    final current = shown.isEmpty ? null : shown.first;
    final currentGrowth = current == null ? null : _growth(buckets, 0);
    final hasSales = shown.any((b) => b.revenue != 0 || (b.refunds ?? 0) > 0);
    final chartPoints = [
      for (var i = shown.length - 1; i >= 0; i--)
        RevenuePoint(
          _granularity == _Granularity.daily ? DateFormat('d').format(shown[i].last) : _day.format(shown[i].last),
          shown[i].revenue,
        ),
    ];
    final rows = _granularity == _Granularity.daily ? shown.take(7).toList() : shown;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        SegmentedButton<_Granularity>(
          segments: const [
            ButtonSegment(value: _Granularity.daily, label: Text('Daily')),
            ButtonSegment(value: _Granularity.weekly, label: Text('Weekly')),
            ButtonSegment(value: _Granularity.monthly, label: Text('30-Day')),
          ],
          selected: {_granularity},
          onSelectionChanged: (s) => setState(() => _granularity = s.first),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(child: _StatBlock(label: 'Current Period', value: '₱${_money.format(current?.revenue ?? 0)}')),
            Expanded(
              child: _StatBlock(
                label: 'Velocity',
                value: '₱${_money.format(current == null ? 0 : current.revenue / current.days)}/d',
              ),
            ),
            Expanded(
              child: _StatBlock(
                label: 'Change',
                value: currentGrowth == null ? '—' : '${currentGrowth >= 0 ? '+' : ''}${currentGrowth.toStringAsFixed(1)}%',
                color: currentGrowth == null ? null : (currentGrowth >= 0 ? AppColors.success : AppColors.error),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                switch (_granularity) {
                  _Granularity.daily => 'NET SALES PER DAY • LAST 14 DAYS',
                  _Granularity.weekly => 'NET SALES PER 7-DAY PERIOD',
                  _Granularity.monthly => 'NET SALES PER 30-DAY PERIOD',
                },
                style: AppTextStyles.labelSm,
              ),
              const SizedBox(height: 10),
              if (hasSales)
                SalesBarChart(points: chartPoints)
              else
                const SizedBox(height: 120, child: Center(child: Text('No sales in this range.'))),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Performance Breakdown', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        if (!hasSales)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('No sales data yet.', style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted))),
          ),
        if (hasSales)
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: AppColors.surfaceContainerLow, shape: BoxShape.rectangle, borderRadius: BorderRadius.all(Radius.circular(10))),
                      child: Text(_label(rows[i], i), style: AppTextStyles.labelMd),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_range(rows[i]), style: AppTextStyles.labelLg)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('₱${_money.format(rows[i].revenue)}', style: AppTextStyles.titleMd),
                        if ((rows[i].refunds ?? 0) > 0)
                          Text('Refunds ₱${_money.format(rows[i].refunds)}', style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                        Builder(builder: (context) {
                          final g = _growth(buckets, i);
                          return Text(
                            g == null ? 'No prior period' : '${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)}%',
                            style: AppTextStyles.bodySm.copyWith(
                              color: g == null ? AppColors.textSecondary : (g >= 0 ? AppColors.success : AppColors.error),
                            ),
                          );
                        }),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Net sales: paid orders − discounts − refunds. A refund counts on the day it was completed '
          '(the sale stays on its own day). Periods are consecutive and end today (Asia/Manila). '
          'Change compares each period with the one before it.',
          style: AppTextStyles.bodySm,
        ),
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _StatBlock({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.bodySm),
          Text(value, style: AppTextStyles.titleMd.copyWith(color: color)),
        ],
      ),
    );
  }
}
