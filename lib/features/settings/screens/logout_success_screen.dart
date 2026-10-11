import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';

class LogoutSuccessScreen extends StatelessWidget {
  const LogoutSuccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(color: AppColors.successBg, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: AppColors.success, size: 46),
              ),
              const SizedBox(height: 16),
              Text('You have been logged out', style: AppTextStyles.headlineMd, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'Thanks for using Melai Nuts Retailing.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Back to Login',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (r) => false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
