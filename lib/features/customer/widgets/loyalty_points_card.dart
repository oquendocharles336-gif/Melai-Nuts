import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// The "Golden Kernel Member" hero card — styled like a physical membership
/// card (matches the prototype's Loyalty Dashboard / Tap Card screens),
/// rather than a generic stats banner.
class LoyaltyPointsCard extends StatelessWidget {
  final int points;
  final String status;
  final String cardNumber;
  final VoidCallback? onTap;

  const LoyaltyPointsCard({
    super.key,
    required this.points,
    required this.status,
    this.cardNumber = 'MLN-RFID-5419',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.darkBrown, AppColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          boxShadow: AppShadows.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.grain_rounded, size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(
                      'MELAI ARTISANAL NUTS',
                      style: AppTextStyles.labelSm.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.contactless_rounded, size: 13, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        'RFID ACTIVE',
                        style: AppTextStyles.labelSm.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              status,
              style: AppTextStyles.headlineSm.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CARD NUMBER',
                        style: AppTextStyles.labelSm.copyWith(color: Colors.white70),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cardNumber,
                        style: AppTextStyles.titleMd.copyWith(
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.qr_code_2_rounded, size: 14, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(
                        'POS Ready',
                        style: AppTextStyles.labelSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
