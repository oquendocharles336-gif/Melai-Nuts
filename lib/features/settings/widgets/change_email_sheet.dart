import 'package:flutter/material.dart';

import '../../../core/services/account_email_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/turnstile_captcha.dart';

/// "Change email": new address + current password. A confirmation link goes to the NEW address
/// and a "was this you?" notice to the current one (Supabase function `account-email`); the
/// account changes only after the link is opened. Returns true when the link was sent.
Future<bool> showChangeEmailSheet(BuildContext context) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _ChangeEmailSheet(),
  );
  return sent ?? false;
}

class _ChangeEmailSheet extends StatefulWidget {
  const _ChangeEmailSheet();

  @override
  State<_ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends State<_ChangeEmailSheet> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _needsCaptcha = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _send({String? captchaToken}) async {
    if (_busy || !FormUtils.validateAndFocus(_formKey)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.requestEmailChange(
        newEmail: _email.text,
        currentPassword: _password.text,
        captchaToken: captchaToken,
      );
      if (!mounted) return;
      final to = _email.text.trim().toLowerCase();
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('We sent a confirmation link to $to. Your email changes after you open it.'),
      ));
    } on AccountEmailException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _needsCaptcha = true;
        _error = e.message;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'change_email_sheet:send');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md, 0, AppSpacing.md, MediaQuery.viewInsetsOf(context).bottom + AppSpacing.md),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(header: true, child: Text('Change email', style: AppTextStyles.headlineMd)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                "We'll send a confirmation link to the new address. Your email changes only after you open it.",
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                label: 'New email',
                controller: _email,
                prefixIcon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                maxLength: InputLimits.email,
                validator: ValidationUtils.validateEmailFormat,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                label: 'Current password',
                controller: _password,
                obscure: true,
                prefixIcon: Icons.lock_outline_rounded,
                autofillHints: const [AutofillHints.password],
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password.' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(_error!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
              ],
              if (_needsCaptcha) ...[
                const SizedBox(height: AppSpacing.sm),
                TurnstileCaptcha(
                  action: 'change_email',
                  onToken: (token) {
                    if (token != null) _send(captchaToken: token);
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              PrimaryButton(
                label: 'Send confirmation link',
                icon: Icons.send_rounded,
                loading: _busy,
                onPressed: _needsCaptcha ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
