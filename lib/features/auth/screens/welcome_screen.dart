import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/motion.dart';
import '../../../core/widgets/page_transitions.dart';
import '../../../data/models/user_role.dart';
import 'login_screen.dart';
import 'register_screen.dart';

/// First screen for someone who is not signed in: brand crest, then Sign In,
/// Create Account and (guests may browse the catalog, see the
/// `_customerBrowse` route policy) Continue as guest.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  void _openSignIn(BuildContext context) {
    Navigator.of(context).push(
      FadeSlideRoute(
        settings: const RouteSettings(name: AppRoutes.login),
        builder: (_) => const LoginScreen(),
      ),
    );
  }

  void _openRegister(BuildContext context) {
    Navigator.of(context).push(FadeSlideRoute(builder: (_) => const RegisterScreen()));
  }

  void _continueAsGuest(BuildContext context) {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.homeFor(UserRole.customer), (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return LuxeSunBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
                  child: Column(
                    children: [
                      const Spacer(),
                      const FadeSlideIn(
                        duration: Duration(milliseconds: 600),
                        child: LuxeCrest(size: 148),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 150),
                        child: Column(
                          children: [
                            Text(
                              AppConstants.appName,
                              textAlign: TextAlign.center,
                              style: AppTextStyles.display,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            const LuxeDivider(width: 160),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              AppConstants.appTagline.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: AppTextStyles.labelMd.copyWith(color: AppColors.primaryDark, letterSpacing: 3),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Fresh-roasted nuts from your Melai Nuts branch.',
                              textAlign: TextAlign.center,
                              style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(flex: 2),
                      const SizedBox(height: AppSpacing.lg),
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 280),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            LuxeGoldButton(label: 'Sign In', onPressed: () => _openSignIn(context)),
                            const SizedBox(height: AppSpacing.sm),
                            OutlinedButton(
                              onPressed: () => _openRegister(context),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primaryDark,
                                side: const BorderSide(color: AppColors.primary, width: 1.4),
                              ),
                              child: const Text('Create Account'),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            TextButton(
                              onPressed: () => _continueAsGuest(context),
                              style: TextButton.styleFrom(foregroundColor: AppColors.primaryDark),
                              child: const Text('Continue as guest'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
