import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/luxe.dart';

/// Asks "Log out?" on a bottom sheet and, once confirmed, shows a short
/// "signing you out" screen, signs out and goes straight to the Login screen
/// (clearing the back stack).
///
/// [beforeSignOut] runs only after the user confirms (e.g. stopping the
/// driver's location tracker).
Future<void> confirmAndLogOut(
  BuildContext context, {
  Future<void> Function()? beforeSignOut,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    backgroundColor: AppColors.ivory,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppSpacing.radiusLg + 4)),
    ),
    builder: (_) => const _LogOutSheet(),
  );
  if (confirmed != true || !context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);

  // Blocking while pending data is flushed and the session ends.
  showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => const PopScope(canPop: false, child: _SigningOutView()),
    transitionBuilder: (context, animation, secondaryAnimation, child) => FadeTransition(opacity: animation, child: child),
  );

  try {
    if (beforeSignOut != null) await beforeSignOut();
    // Long enough to read, even when there is nothing to flush.
    await Future.wait<void>([
      AuthService.instance.signOut(),
      Future<void>.delayed(const Duration(milliseconds: 700)),
    ]);
  } catch (caughtError, caughtStack) {
    AppErrors.report(caughtError, caughtStack, 'logout_flow:signOut');
    navigator.pop(); // close the signing-out screen
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not log out. Please try again.')),
    );
    return;
  }

  navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
}

/// The Log Out action at the bottom of an account screen.
class LogOutButton extends StatelessWidget {
  final Future<void> Function()? beforeSignOut;

  const LogOutButton({super.key, this.beforeSignOut});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppSpacing.radiusMd);
    return Material(
      color: AppColors.errorBg.withValues(alpha: 0.55),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => confirmAndLogOut(context, beforeSignOut: beforeSignOut),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                child: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Log Out', style: AppTextStyles.titleMd.copyWith(color: AppColors.error)),
                    Text('Sign out of this device', style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.error),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogOutSheet extends StatelessWidget {
  const _LogOutSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.7, end: 1),
              duration: const Duration(milliseconds: 500),
              curve: Curves.elasticOut,
              builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
              child: const Center(child: AppLogo(size: 84)),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Leaving already?', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'You will need to sign in again to use the app.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd,
            ),
            const SizedBox(height: AppSpacing.lg),
            // Staying is the safe choice, so an accidental Enter does nothing.
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Stay Signed In'),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: AppColors.error, minimumSize: const Size(64, 50)),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Log Out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SigningOutView extends StatefulWidget {
  const _SigningOutView();

  @override
  State<_SigningOutView> createState() => _SigningOutViewState();
}

class _SigningOutViewState extends State<_SigningOutView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LuxeSunBackground(
      child: Material(
        type: MaterialType.transparency,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: Tween<double>(begin: 0.94, end: 1.06).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: const LuxeCrest(size: 120),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Signing you out', style: AppTextStyles.headlineMd),
              const SizedBox(height: AppSpacing.xs),
              Text('See you again soon!', style: AppTextStyles.bodyMd.copyWith(color: AppColors.primaryDark)),
            ],
          ),
        ),
      ),
    );
  }
}
