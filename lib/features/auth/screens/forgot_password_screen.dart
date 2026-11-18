import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/widgets/info_banner.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/services/account_email_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/widgets/turnstile_captcha.dart';
import '../../../core/utils/app_error.dart';

/// "Account Security Recovery" — request a password reset link.
///
/// Sends our own password-reset email (single-use link, Supabase function
/// `account-email`). The link opens ResetPasswordLinkScreen in the app (or the
/// website's page), so this screen's job ends once the email is sent. Without
/// App Check the server asks for the security check first, shown here.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _sending = false;
  bool _needsCaptcha = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetCode({String? captchaToken}) async {
    if (!FormUtils.validateAndFocus(_formKey)) return;

    setState(() => _sending = true);
    try {
      await AuthService.instance.sendPasswordResetEmail(_emailController.text, captchaToken: captchaToken);
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          // Same text whether or not the address has an account (no account enumeration).
          content: Text("If an account exists for this email, we've sent a reset link."),
        ),
      );
      Navigator.of(context).popUntil((r) => r.settings.name == AppRoutes.login);
    } on AccountEmailException catch (e) {
      // The server wants the security check (no App Check on this device): show it.
      if (!mounted) return;
      setState(() {
        _sending = false;
        _needsCaptcha = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'forgot_password_screen:47');
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Melai Nuts Retailing', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Form(
              key: _formKey,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.md,
                ),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.vpn_key_rounded,
                        color: AppColors.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('ACCOUNT SECURITY RECOVERY', style: AppTextStyles.labelSm),
                    const SizedBox(height: 6),
                    Text(
                      'Reset Your Password',
                      style: AppTextStyles.headlineLg.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter the email of your Melai Nuts account and we\'ll send you a link to choose a new password.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyMd,
                    ),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Email Address', style: AppTextStyles.labelLg),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      maxLength: InputLimits.email,
                      validator: ValidationUtils.validateEmailFormat,
                      decoration: const InputDecoration(
                        counterText: '',
                        prefixIcon: Icon(
                          Icons.email_outlined,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'The link works once and expires in 30 minutes.',
                        style: AppTextStyles.bodySm,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const InfoBanner(
                      text:
                      'We will email you a link to reset your password.',
                    ),
                    const SizedBox(height: 20),
                    if (_needsCaptcha) ...[
                      TurnstileCaptcha(
                        action: 'reset_password',
                        onToken: (token) {
                          if (token != null) _sendResetCode(captchaToken: token);
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    PrimaryButton(
                      label: 'Send reset link',
                      icon: Icons.send_rounded,
                      loading: _sending,
                      onPressed: _needsCaptcha ? null : _sendResetCode,
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back to Login'),
                    ),
                    const SizedBox(height: 8),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text(
                      'Having trouble? Ask the store owner or your branch staff for help.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodySm,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}