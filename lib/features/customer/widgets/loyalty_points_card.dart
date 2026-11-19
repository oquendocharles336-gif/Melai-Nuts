import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// The "Golden Kernel Member" hero card — styled like a physical membership
/// card (matches the prototype's Loyalty Dashboard / Tap Card screens),
/// rather than a generic stats banner.
///
/// The RFID status comes from the customer's real linked card
/// ([cardNumber] = customer_profiles.rfid_card_number, which the database
/// keeps equal to the label of their ACTIVE card and clears when there is none
/// or it is blocked). "RFID ACTIVE" only with a linked card; otherwise
/// "NO CARD LINKED" and a "Link a card" hint.
class LoyaltyPointsCard extends StatelessWidget {
  final int points;
  final String status;
  final String? cardNumber;
  final VoidCallback? onTap;

  const LoyaltyPointsCard({
    super.key,
    required this.points,
    required this.status,
    this.cardNumber,
    this.onTap,
  });

  /// A card is registered to this account.
  bool get hasCard => (cardNumber?.trim() ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd],
          ),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
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
                      Icon(hasCard ? Icons.contactless_rounded : Icons.link_off_rounded, size: 13, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        hasCard ? 'RFID ACTIVE' : 'NO CARD LINKED',
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
                        hasCard ? cardNumber!.trim() : 'Not linked yet',
                        style: AppTextStyles.titleMd.copyWith(
                          color: hasCard ? Colors.white : Colors.white70,
                          letterSpacing: hasCard ? 1.2 : 0,
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
                      Icon(hasCard ? Icons.qr_code_2_rounded : Icons.add_link_rounded, size: 14, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(
                        hasCard ? 'POS Ready' : 'Link a card',
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
