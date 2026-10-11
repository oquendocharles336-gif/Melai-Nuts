import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/loyalty.dart';

class RedemptionSuccessScreen extends StatelessWidget {
  const RedemptionSuccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final result = ModalRoute.of(context)!.settings.arguments as RedemptionResult;
    final reward = result.reward;
    final userPointsAfter = result.pointsAfter;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(AppSpacing.xl),
                decoration: const BoxDecoration(
                  color: AppColors.successBg,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.redeem,
                  size: 100,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Redemption Successful!',
                textAlign: TextAlign.center,
                style: AppTextStyles.headlineLg,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'You have successfully redeemed:',
                style: AppTextStyles.bodyMd,
              ),
              Text(
                reward.title,
                textAlign: TextAlign.center,
                style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
              ),
              const SizedBox(height: AppSpacing.xl),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  boxShadow: AppShadows.sm,
                ),
                child: Column(
                  children: [
                    Text(
                      'Updated Balance',
                      style: AppTextStyles.labelMd,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '$userPointsAfter Points',
                      style: AppTextStyles.headlineSm.copyWith(color: AppColors.textPrimary),
                    ),
                    Text(
                      '-${reward.pointsRequired} points used',
                      style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Show the QR code in your profile to claim this reward at any branch.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySm,
              ),
              const Spacer(),
              PrimaryButton(
                label: 'Back to Loyalty Dashboard',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.popUntil(context, ModalRoute.withName('/customer/loyalty')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
