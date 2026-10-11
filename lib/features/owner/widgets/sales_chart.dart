import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/sales_data.dart';

/// A compact bar chart for revenue/orders series (7-day trend, monthly
/// trend, forecast trajectory). Built with plain Containers rather than a
/// charting package, matching the rest of the app's dependency-light
/// approach (progress bars, gauges, etc. are all hand-rolled too).
class SalesBarChart extends StatelessWidget {
  final List<RevenuePoint> points;
  final double height;
  final bool showValues;

  const SalesBarChart({
    super.key,
    required this.points,
    this.height = 160,
    this.showValues = true,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    // Net sales can be negative on a day with more refunds than sales: such a
    // bar is drawn at the minimum height, and an all-negative series still scales.
    final highest = points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final maxValue = highest > 0 ? highest : 1.0;

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final point in points)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showValues)
                      Text(
                        _formatCompact(point.value),
                        style: AppTextStyles.bodySm,
                        textAlign: TextAlign.center,
                      ),
                    const SizedBox(height: 4),
                    Container(
                      height: (height - 50) * (point.value / maxValue).clamp(0.05, 1.0),
                      decoration: BoxDecoration(
                        color: point.isProjection ? AppColors.primary.withValues(alpha: 0.35) : AppColors.primary,
                        borderRadius: BorderRadius.circular(4),
                        border: point.isProjection ? Border.all(color: AppColors.primary, width: 1.2) : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(point.label, style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatCompact(double value) {
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return value.toStringAsFixed(0);
  }
}
