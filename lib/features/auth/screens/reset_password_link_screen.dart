import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';

enum _LinkState { checking, form, saving, done, invalid }

/// The landing page of the password-reset e-mail inside the app.
///
/// Firebase's reset e-mail links to `https://<website>/auth/action?mode=resetPassword&oobCode=…`
/// (Firebase console > Authentication > Templates > Password reset > Customize action URL). On a
/// phone with the app installed, Android opens that link here (App Link, see
/// android/app/build.gradle.kts `melaiWebHost`); anywhere else the website shows the same form.
///
/// The code is checked with Firebase first, the new password must pass the app's password rules,
/// and Firebase accepts each code only once: after the change the link no longer works, and the
/// account's other sign-ins end (Firebase revokes them on a password change).
class ResetPasswordLinkScreen extends StatefulWidget {
  const ResetPasswordLinkScreen({super.key, required this.link});

  /// The route name the link arrived as, e.g. `/auth/action?mode=resetPassword&oobCode=…`.
  final String link;

  @override
  State<ResetPasswordLinkScreen> createState() => _ResetPasswordLinkScreenState();
}

class _ResetPasswordLinkScreenState extends State<ResetPasswordLinkScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  _LinkState _state = _LinkState.checking;
  String? _code;
  String? _email;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final uri = Uri.tryParse(widget.link);
    final mode = uri?.queryParameters['mode'];
    final code = uri?.queryParameters['oobCode'];
    if (mode != 'resetPassword' || code == null || code.isEmpty) {
      setState(() {
        _state = _LinkState.invalid;
        _error = 'This link is not a password-reset link. Open the link from the most recent Melai Nuts e-mail.';
      });
      return;
    }
    try {
      final email = await FirebaseAuth.instance.verifyPasswordResetCode(code);
      if (!mounted) return;
      setState(() {
        _code = code;
        _email = email;
        _state = _LinkState.form;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LinkState.invalid;
        _error = _messageFor(e);
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'reset_password_link:check');
      if (!mounted) return;
      setState(() {
        _state = _LinkState.invalid;
        _error = 'We could not check this link. Please check your connection and open it again.';
      });
    }
  }

  Future<void> _save() async {
    final code = _code;
    if (code == null || _state == _LinkState.saving) return;
    if (!FormUtils.validateAndFocus(_formKey)) return;
    setState(() {
      _state = _LinkState.saving;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.confirmPasswordReset(code: code, newPassword: _password.text);
      if (!mounted) return;
      setState(() => _state = _LinkState.done);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final expired = e.code == 'expired-action-code' || e.code == 'invalid-action-code';
      setState(() {
        _state = expired ? _LinkState.invalid : _LinkState.form;
        _error = _messageFor(e);
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'reset_password_link:save');
      if (!mounted) return;
      setState(() {
        _state = _LinkState.form;
        _error = 'We could not change your password. Please check your connection and try again.';
      });
    }
  }

  String _messageFor(FirebaseAuthException e) {
    switch (e.code) {
      case 'expired-action-code':
        return 'This reset link has expired. Request a new one from "Forgot password?".';
      case 'invalid-action-code':
        return 'This reset link was already used or is not valid anymore. Request a new one from "Forgot password?".';
      case 'user-disabled':
        return 'This account has been disabled. Please contact Melai Nuts.';
      case 'user-not-found':
        return 'This account no longer exists.';
      case 'weak-password':
        return 'That password is too weak. Please choose a stronger one.';
      case 'network-request-failed':
        return 'Network error. Please check your connection and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  void _toSignIn() {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.splash, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Reset Password'),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(AppSpacing.lg), children: _body())),
    );
  }

  List<Widget> _body() {
    switch (_state) {
      case _LinkState.checking:
        return const [SizedBox(height: 80), Center(child: CircularProgressIndicator())];
      case _LinkState.invalid:
        return [
          const Icon(Icons.link_off_rounded, size: 56, color: AppColors.error),
          const SizedBox(height: AppSpacing.md),
          Text('Link not valid', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
          const SizedBox(height: 8),
          Text(_error ?? '', textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(
            label: 'Request a new link',
            icon: Icons.mail_outline_rounded,
            onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.forgotPassword, (_) => false),
          ),
        ];
      case _LinkState.done:
        return [
          const Icon(Icons.check_circle_rounded, size: 56, color: AppColors.success),
          const SizedBox(height: AppSpacing.md),
          Text('Password changed', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
          const SizedBox(height: 8),
          Text(
            'Sign in with your new password. This link no longer works, and you were signed out on your other devices.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMd,
          ),
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(label: 'Sign in', icon: Icons.login_rounded, onPressed: _toSignIn),
        ];
      case _LinkState.form:
      case _LinkState.saving:
        final saving = _state == _LinkState.saving;
        return [
          Text('Choose a new password for ${_email ?? 'your account'}.', style: AppTextStyles.bodyMd),
          const SizedBox(height: AppSpacing.md),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (v) => ValidationUtils.validatePassword(v, email: _email),
                  decoration: InputDecoration(
                    labelText: 'New password',
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _confirm,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (v) => v == _password.text ? null : 'The passwords do not match.',
                  decoration: const InputDecoration(labelText: 'Confirm new password'),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
          ],
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(label: 'Save new password', icon: Icons.lock_reset_rounded, loading: saving, onPressed: _save),
        ];
    }
  }
}
