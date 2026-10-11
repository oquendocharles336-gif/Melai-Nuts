import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';

/// Confirms the password reset succeeded, then routes back to Login.
class PasswordResetSuccessScreen extends StatelessWidget {
  const PasswordResetSuccessScreen({super.key});

  void _backToLogin(BuildContext context) {
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Melai Nuts Retailing'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.md,
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Authentication Workflow • Complete',
                      style: AppTextStyles.labelMd,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 84,
                    height: 84,
                    decoration: const BoxDecoration(
                      color: AppColors.successBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: AppColors.success,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Password Reset\nSuccessfully!',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.headlineLg.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your Melai Nuts portal account password has been updated. You can now use your new password to sign in across POS registers and management dashboards.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMd,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.sm,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.badge_outlined,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ACCOUNT RECOVERED',
                                style: AppTextStyles.labelSm,
                              ),
                              Text(
                                'Your account is ready',
                                style: AppTextStyles.labelLg,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Laguna Branch Network',
                                style: AppTextStyles.bodySm,
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.verified_user_outlined,
                          size: 18,
                          color: AppColors.darkBrown,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: AppTextStyles.bodySm,
                              children: [
                                TextSpan(
                                  text: 'Security notice: ',
                                  style: AppTextStyles.labelMd.copyWith(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                const TextSpan(
                                  text:
                                      'All other active sessions on Laguna branch handheld terminals have been securely logged out.',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  PrimaryButton(
                    label: 'Proceed to Login',
                    icon: Icons.arrow_forward_rounded,
                    onPressed: () => _backToLogin(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
