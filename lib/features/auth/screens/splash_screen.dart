import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/user_role.dart';
import 'email_verification_screen.dart';

/// First screen shown on launch. Runs a short "connecting to branch
/// network" animation while, in parallel, checking whether someone is
/// already signed in (Firebase persists sessions across app restarts) so
/// returning users land straight back in their portal instead of Login.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _resolving = false;

  Future<void> _proceed() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final profile = await AuthService.instance.loadCurrentProfile(
        allowVerificationResume: true,
      );
      if (!mounted) return;
      if (profile != null) {
        final destination = profile.role == UserRole.customer
            ? AppRoutes.homeFor(UserRole.customer)
            : AppRoutes.homeFor(profile.role);
        Navigator.of(context).pushReplacementNamed(destination);
        return;
      }
    } on EmailVerificationRequiredException {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
      );
      return;
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      // Ignore — e.g. no network on first launch. Fall through to Login,
      // which will surface a clearer error on the actual sign-in attempt.
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.primaryContainer, AppColors.surface, AppColors.canvas],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      const Spacer(flex: 3),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.25),
                              blurRadius: 32,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: const AppLogo(size: 104),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        AppConstants.appName,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.headlineLg.copyWith(
                          color: AppColors.darkBrown,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppConstants.appTagline,
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Fresh-roasted nuts from your nearest Laguna branch.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // Real branch names, only once they have loaded (nothing is shown otherwise).
                          for (final b in kBranches.map((b) => b.name))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.storefront_rounded, size: 14, color: AppColors.primary),
                                  const SizedBox(width: 6),
                                  Text(b.split(' ').first, style: AppTextStyles.labelMd),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const Spacer(flex: 4),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: _resolving ? null : _proceed,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: _resolving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('Get Started'),
                                    SizedBox(width: 8),
                                    Icon(Icons.arrow_forward_rounded, size: 20),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Melai Nuts Retailing • Calamba • Los Baños • Santa Cruz',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodySm,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
