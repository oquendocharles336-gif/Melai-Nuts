import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/staff_session_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';

/// Shown by `RouteGuard` in place of any staff screen until the server has
/// confirmed the signed-in staff member's profile, branch and permissions
/// ([StaffSessionStore.isReady]).
///
///  * loading           -> spinner
///  * failed            -> what went wrong + Retry (staff stay locked out until
///                         the server answers: fail closed)
///  * denied (not set up / deactivated / suspended / invalid role or branch)
///                      -> explanation + Sign out
///
/// Staff screens are therefore never built with another account's data, with
/// no branch, or with unverified permissions.
class StaffSessionBlockedView extends StatefulWidget {
  const StaffSessionBlockedView({super.key});

  @override
  State<StaffSessionBlockedView> createState() => _StaffSessionBlockedViewState();
}

class _StaffSessionBlockedViewState extends State<StaffSessionBlockedView> {
  bool _busy = false;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await StaffSessionStore.instance.refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AuthService.instance.signOut();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sign out. Please try again.')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final store = StaffSessionStore.instance;
    final status = store.status;
    final denied = status.isDenied;
    final loading = !denied &&
        (status == StaffSessionStatus.loading ||
            status == StaffSessionStatus.signedOut ||
            _busy);

    if (loading) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final String title;
    switch (status) {
      case StaffSessionStatus.notProvisioned:
        title = 'Account not set up';
      case StaffSessionStatus.inactive:
        title = 'Account deactivated';
      case StaffSessionStatus.suspended:
        title = 'Account suspended';
      case StaffSessionStatus.invalidRole:
        title = 'Role not recognised';
      case StaffSessionStatus.invalidBranch:
        title = 'No valid branch';
      default:
        title = "Can't verify your account";
    }
    // Every message comes from AppErrors: fixed, person-readable, no internals.
    final message = store.accessError?.message ??
        'We could not confirm your staff access right now. '
            'Please check your connection and try again.';
    // Denied accounts cannot fix this by retrying; only a failed check can.
    final canRetry = !denied;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 48, color: AppColors.roleStaff),
                const SizedBox(height: AppSpacing.md),
                Text(title, style: AppTextStyles.headlineSm, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  message,
                  style: AppTextStyles.bodyMd.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (canRetry)
                  FilledButton(onPressed: _busy ? null : _retry, child: const Text('Try again')),
                TextButton(onPressed: _busy ? null : _signOut, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown by `RouteGuard` when the staff session is confirmed but the account
/// lacks a permission the screen requires. The database refuses the same
/// actions regardless; this just explains why the screen is not available.
class StaffPermissionDeniedView extends StatelessWidget {
  const StaffPermissionDeniedView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 48, color: AppColors.roleStaff),
                const SizedBox(height: AppSpacing.md),
                Text('Not available', style: AppTextStyles.headlineSm, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  AppErrors.accessDenied().message,
                  style: AppTextStyles.bodyMd.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
