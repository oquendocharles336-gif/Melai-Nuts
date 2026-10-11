import 'package:flutter/material.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import 'logout_success_screen.dart';

class LogoutConfirmationScreen extends StatefulWidget {
  const LogoutConfirmationScreen({super.key});

  @override
  State<LogoutConfirmationScreen> createState() => _LogoutConfirmationScreenState();
}

class _LogoutConfirmationScreenState extends State<LogoutConfirmationScreen> {
  bool _busy = false;

  /// Actually ends the Firebase session (previously this screen only
  /// navigated, leaving the user signed in and auto-restored on next launch).
  Future<void> _logOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AuthService.instance.signOut();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not log out. Please try again.')),
      );
      return;
    }
    if (!mounted) return;
    // Clear the stack so Back can't return to a portal from the old session.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LogoutSuccessScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Log Out', showBack: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(color: AppColors.warningBg, shape: BoxShape.circle),
                child: const Icon(Icons.logout_rounded, color: AppColors.warning, size: 42),
              ),
              const SizedBox(height: 16),
              Text('Log out of Melai Nuts?', style: AppTextStyles.headlineMd, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'You will need to sign in again to access your account.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Log Out',
                icon: Icons.logout_rounded,
                onPressed: _logOut,
                loading: _busy,
              ),
              const SizedBox(height: 10),
              SecondaryButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            ],
          ),
        ),
      ),
    );
  }
}
