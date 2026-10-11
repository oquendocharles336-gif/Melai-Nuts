import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/owner_sales.dart';

/// One branch's net sales at a glance (today, the last 7 days, orders, refunds),
/// with an optional rank badge. Built only from [OwnerBranchSales], which the
/// database computes.
class OwnerBranchTile extends StatelessWidget {
  final OwnerBranchSales sales;
  final int? rank;
  final VoidCallback onTap;

  const OwnerBranchTile({super.key, required this.sales, required this.onTap, this.rank});

  static final _money = NumberFormat('#,##0.00');

  @override
  Widget build(BuildContext context) {
    final week = sales.week;
    final pending = sales.pendingRefundAmount;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Row(
          children: [
            if (rank != null) ...[
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                child: Text('$rank', style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sales.name, style: AppTextStyles.labelLg),
                  const SizedBox(height: 2),
                  Text(
                    '${sales.ordersToday} order${sales.ordersToday == 1 ? '' : 's'} today • '
                    '${sales.ordersWeek} in 7 days • Avg ${pesoOrDash(week?.averageOrderValue)}',
                    style: AppTextStyles.bodySm,
                  ),
                  if (week != null && week.refunds > 0)
                    Text('Refunds 7d: ${peso(week.refunds)} (${week.refundCount})', style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                  if (pending != null && pending > 0)
                    Text('${peso(pending)} refunds pending', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₱${_money.format(sales.todayRevenue)}', style: AppTextStyles.labelLg.copyWith(color: AppColors.roleOwner)),
                Text('₱${_money.format(sales.weekRevenue)} / 7d', style: AppTextStyles.bodySm),
              ],
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
