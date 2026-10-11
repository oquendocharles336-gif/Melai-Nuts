import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/loyalty.dart';

class LoyaltyTransactionScreen extends StatelessWidget {
  const LoyaltyTransactionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tx = ModalRoute.of(context)!.settings.arguments as LoyaltyPointTransaction;
    final isEarn = tx.type == LoyaltyTransactionType.earn;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Transaction Details', showBack: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: isEarn ? AppColors.successBg : AppColors.errorBg,
                    child: Icon(
                      isEarn ? Icons.add : Icons.remove,
                      color: isEarn ? AppColors.success : AppColors.error,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '${isEarn ? '+' : '-'}${tx.points} Points',
                    style: AppTextStyles.headlineLg.copyWith(
                      color: isEarn ? AppColors.success : AppColors.error,
                    ),
                  ),
                  Text(
                    isEarn ? 'Points Earned' : 'Points Redeemed',
                    style: AppTextStyles.bodyMd,
                  ),
                  const Divider(height: AppSpacing.xl2),
                  _buildDetailRow('Transaction ID', tx.id),
                  _buildDetailRow('Date', '${tx.date.day}/${tx.date.month}/${tx.date.year}'),
                  _buildDetailRow('Time', '${tx.date.hour}:${tx.date.minute}'),
                  _buildDetailRow('Description', tx.description),
                  const Divider(height: AppSpacing.xl2),
                  _buildDetailRow('Status', 'Completed', color: AppColors.success),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.labelMd),
          Text(
            value,
            style: AppTextStyles.bodyMd.copyWith(
              color: color ?? AppColors.textPrimary,
              fontWeight: color != null ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}
