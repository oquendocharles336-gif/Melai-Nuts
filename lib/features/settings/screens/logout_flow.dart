import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/confirm_dialog.dart';

/// Asks "Log out?" and, once confirmed, signs out and goes straight to the
/// Login screen (clearing the back stack). No intermediate "logged out" page.
///
/// [beforeSignOut] runs only after the user confirms (e.g. stopping the
/// driver's location tracker).
Future<void> confirmAndLogOut(
  BuildContext context, {
  Future<void> Function()? beforeSignOut,
}) async {
  final confirmed = await ConfirmDialog.show(
    context,
    title: 'Log out?',
    message: 'You will need to sign in again to use the app.',
    confirmLabel: 'Log Out',
    icon: Icons.logout_rounded,
  );
  if (!confirmed || !context.mounted) return;

  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);

  // Small blocking spinner while pending data is flushed and the session ends.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );

  try {
    if (beforeSignOut != null) await beforeSignOut();
    await AuthService.instance.signOut();
  } catch (caughtError, caughtStack) {
    AppErrors.report(caughtError, caughtStack, 'logout_flow:signOut');
    navigator.pop(); // close the spinner
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not log out. Please try again.')),
    );
    return;
  }

  navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
}
