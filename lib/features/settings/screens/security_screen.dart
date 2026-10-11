import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Account Security', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.vpn_key_rounded, color: AppColors.darkBrown),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Password', style: AppTextStyles.titleMd)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Change your password any time. You will need access to your account email.', style: AppTextStyles.bodyMd),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.resetPassword),
                    child: Row(
                      children: [
                        const Icon(Icons.restart_alt_rounded, size: 18, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Change Password', style: AppTextStyles.labelLg.copyWith(color: AppColors.primary)),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
                      ],
                    ),
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
