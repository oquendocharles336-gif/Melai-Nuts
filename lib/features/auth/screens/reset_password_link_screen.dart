import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/account_email_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';

enum _LinkState { checking, form, saving, done, invalid, emailConfirm, emailCancel, emailDone }

/// The landing page of the password-reset e-mail inside the app.
///
/// Our account e-mails (Supabase function `account-email`) link to
/// `https://<website>/auth/action?mode=resetPassword|confirmEmail|cancelEmailChange&token=…`.
/// On a phone with the app installed, Android opens that link here (App Link, see
/// android/app/build.gradle.kts `melaiWebHost`); anywhere else the website shows the same page.
///
/// Reset: the link is checked first (not used up), the new password must pass the app's rules,
/// and the link works once; afterwards the account's other sign-ins end. E-mail change: one tap
/// confirms (from the new address) or stops it (from the old one). Old Firebase links
/// (`oobCode=…`) are answered with "ask for a new link".
class ResetPasswordLinkScreen extends StatefulWidget {
  const ResetPasswordLinkScreen({super.key, required this.link});

  /// The route name the link arrived as, e.g. `/auth/action?mode=resetPassword&token=…`.
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
  bool _busy = false;
  String _doneText = '';

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
    final token = uri?.queryParameters['token'];
    if (token == null || token.isEmpty) {
      setState(() {
        _state = _LinkState.invalid;
        _error = uri?.queryParameters['oobCode'] != null
            ? 'This link is from an older email and no longer works. Request a new one from "Forgot password?".'
            : 'This link is not complete. Open the link from the most recent Melai Nuts email.';
      });
      return;
    }
    _code = token;
    if (mode == 'confirmEmail' || mode == 'cancelEmailChange') {
      setState(() => _state = mode == 'confirmEmail' ? _LinkState.emailConfirm : _LinkState.emailCancel);
      return;
    }
    if (mode != 'resetPassword') {
      setState(() {
        _state = _LinkState.invalid;
        _error = 'This link is not one of ours. Open the link from the most recent Melai Nuts email.';
      });
      return;
    }
    try {
      final email = await AccountEmailService.instance.checkPasswordReset(token);
      if (!mounted) return;
      setState(() {
        _email = email;
        _state = _LinkState.form;
      });
    } on AccountEmailException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LinkState.invalid;
        _error = e.message;
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
      await AccountEmailService.instance.confirmPasswordReset(code, _password.text);
      if (!mounted) return;
      setState(() => _state = _LinkState.done);
    } on AccountEmailException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = e.isLinkProblem ? _LinkState.invalid : _LinkState.form;
        _error = e.message;
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

  /// Confirm (new address) or stop (old address) an e-mail change: one tap, the link works once.
  Future<void> _emailAction() async {
    final code = _code;
    final confirming = _state == _LinkState.emailConfirm;
    if (code == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (confirming) {
        final email = await AccountEmailService.instance.confirmEmailChange(code);
        _doneText = 'Your Melai Nuts account now uses $email. Sign in again with this address.';
      } else {
        await AccountEmailService.instance.cancelEmailChange(code);
        _doneText = 'The email change was stopped; your account keeps its current email. If you did not ask for it, change your password now.';
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = _LinkState.emailDone;
      });
    } on AccountEmailException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = e.isLinkProblem ? _LinkState.invalid : _state;
        _error = e.message;
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'reset_password_link:email');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Please check your connection and try again.';
      });
    }
  }

  void _toSignIn() {
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.splash, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Your account'),
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
      case _LinkState.emailConfirm:
      case _LinkState.emailCancel:
        final confirming = _state == _LinkState.emailConfirm;
        return [
          Icon(confirming ? Icons.mark_email_read_rounded : Icons.shield_rounded, size: 56, color: AppColors.primary),
          const SizedBox(height: AppSpacing.md),
          Text(confirming ? 'Confirm your new email' : 'Stop the email change?',
              textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
          const SizedBox(height: 8),
          Text(
            confirming
                ? "Your Melai Nuts account will use this address from now on. You'll sign in again on your devices."
                : "Your account keeps its current email. If you didn't ask for this change, change your password afterwards.",
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMd,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
          ],
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(
            label: confirming ? 'Confirm new email' : 'Stop this change',
            icon: confirming ? Icons.check_rounded : Icons.block_rounded,
            loading: _busy,
            onPressed: _emailAction,
          ),
        ];
      case _LinkState.emailDone:
        return [
          const Icon(Icons.check_circle_rounded, size: 56, color: AppColors.success),
          const SizedBox(height: AppSpacing.md),
          Text('Done', textAlign: TextAlign.center, style: AppTextStyles.headlineMd),
          const SizedBox(height: 8),
          Text(_doneText, textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
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
