import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/loyalty.dart';

/// A single row in the "Available Rewards" list — matches the prototype's
/// Redeem Rewards screen: badge label, title/description, points cost, and
/// a claim/redeem button on the right.
class RewardCard extends StatelessWidget {
  final RewardItem reward;
  final bool canRedeem;
  final VoidCallback onRedeem;

  const RewardCard({
    super.key,
    required this.reward,
    required this.canRedeem,
    required this.onRedeem,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: reward.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    reward.badgeLabel,
                    style: AppTextStyles.labelSm.copyWith(color: reward.color),
                  ),
                ),
                const SizedBox(height: 8),
                Text(reward.title, style: AppTextStyles.titleMd),
                const SizedBox(height: 2),
                Text(reward.description, style: AppTextStyles.bodySm),
                const SizedBox(height: 10),
                Text(
                  '${reward.pointsRequired} pts',
                  style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: reward.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(reward.icon, color: reward.color),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: canRedeem ? onRedeem : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('Claim'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
