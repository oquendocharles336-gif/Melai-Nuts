import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/form_utils.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../app/post_sign_in.dart';
import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/widgets/turnstile_captcha.dart';
import '../../../data/models/user_role.dart';
import '../../../core/utils/app_error.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Final step of customer sign-up: proves the person owns the email address.
///
/// Melai Nuts e-mails a 6-digit code (no link). The person types it and passes a
/// security check (Cloudflare Turnstile); the server checks the captcha BEFORE the code.
///
/// The account exists but has NO profile (and therefore no access) until this
/// succeeds. Firestore rules independently refuse the profile write unless
/// Firebase reports the email as verified, so this screen cannot be bypassed
/// by a modified app.
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  static const int _resendSeconds = 60;

  final _codeController = TextEditingController();
  final _codeFormKey = GlobalKey<FormState>();
  final _sendCaptchaKey = GlobalKey<TurnstileCaptchaState>();
  final _verifyCaptchaKey = GlobalKey<TurnstileCaptchaState>();

  Timer? _timer;
  int _cooldown = 0;
  bool _sending = false;
  bool _verifying = false;

  /// The server wants a captcha before it sends a code (no App Check on this device).
  bool _sendNeedsCaptcha = false;
  String? _verifyToken;

  String get _email => AuthService.instance.currentFirebaseUser?.email ?? 'your email';

  @override
  void initState() {
    super.initState();
    if (AuthService.instance.currentFirebaseUser == null) {
      // Nothing to verify (e.g. opened while signed out).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (r) => false);
        }
      });
      return;
    }
    _send();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown([int seconds = _resendSeconds]) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = _cooldown > 0 ? _cooldown - 1 : 0);
      if (_cooldown == 0) t.cancel();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send({String? captchaToken}) async {
    if (_sending || _cooldown > 0) return;
    setState(() => _sending = true);
    try {
      await AuthService.instance.sendVerification(captchaToken: captchaToken);
      if (!mounted) return;
      setState(() => _sendNeedsCaptcha = false);
      _startCooldown();
      _toast(AppLocalizations.of(context).verifyCodeSent(_email));
    } on CaptchaNeededException catch (e) {
      if (!mounted) return;
      setState(() => _sendNeedsCaptcha = true);
      if (e.rejected) {
        _sendCaptchaKey.currentState?.reset();
        _toast(e.message);
      }
    } on AuthException catch (e) {
      _toast(e.message);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'email_verification_screen:send');
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    if (_verifying) return;
    if (!FormUtils.validateAndFocus(_codeFormKey)) return;
    final t = AppLocalizations.of(context);
    final token = _verifyToken;
    if (token == null) {
      _toast(t.verifyCompleteCheckFirst);
      return;
    }
    setState(() => _verifying = true);
    // A token works once, whatever the answer: the next try needs a fresh check.
    _verifyToken = null;
    try {
      final user = await AuthService.instance.completeCustomerRegistration(
        // Keep digits only (ignores spaces/dashes people paste with the code).
        code: _codeController.text.replaceAll(RegExp(r'\D'), ''),
        captchaToken: token,
      );
      if (!mounted) return;
      _toast('Welcome, ${user.name}! Your account is ready.');
      // Home, or back to the cart when Checkout sent them to sign up.
      PostSignIn.go(Navigator.of(context), UserRole.customer);
      return;
    } on AuthException catch (e) {
      _toast(e.message);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'email_verification_screen:verify');
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
    _verifyCaptchaKey.currentState?.reset();
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel sign-up?'),
        content: const Text(
          'Your unverified account will be removed and you can start again with a different email.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Cancel sign-up')),
        ],
      ),
    );
    if (confirmed != true) return;
    await AuthService.instance.cancelCustomerRegistration();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: const MelaiAppBar(title: 'Verify Your Email'),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              const SizedBox(height: 12),
              const Icon(Icons.mark_email_read_outlined, size: 64, color: AppColors.primary),
              const SizedBox(height: 16),
              Text(
                'Check your inbox',
                textAlign: TextAlign.center,
                style: AppTextStyles.headlineMd,
              ),
              const SizedBox(height: 8),
              Text(
                _sendNeedsCaptcha ? t.verifySendNeedsCheck(_email) : t.verifyCodeIntro(_email),
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_sendNeedsCaptcha) ...[
                TurnstileCaptcha(
                  key: _sendCaptchaKey,
                  action: 'send_code',
                  onToken: (token) {
                    if (token != null) _send(captchaToken: token);
                  },
                ),
                if (_sending) ...[
                  const SizedBox(height: 12),
                  const Center(child: CircularProgressIndicator()),
                ],
              ] else ...[
                Form(
                  key: _codeFormKey,
                  child: AppTextField(
                    label: 'Verification code',
                    controller: _codeController,
                    prefixIcon: Icons.pin_outlined,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: InputRules.verificationCode(),
                    textInputAction: TextInputAction.done,
                    hint: '6-digit code',
                    validator: ValidationUtils.validateVerificationCode,
                    onFieldSubmitted: (_) => _verify(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(height: 12),
                TurnstileCaptcha(
                  key: _verifyCaptchaKey,
                  action: 'verify_email',
                  onToken: (token) => setState(() => _verifyToken = token),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Verify & Create Account',
                  icon: Icons.verified_rounded,
                  loading: _verifying,
                  onPressed: _verifyToken == null ? null : _verify,
                ),
                if (_verifyToken == null) ...[
                  const SizedBox(height: 6),
                  Text(t.verifyCompleteCheckFirst, textAlign: TextAlign.center, style: AppTextStyles.bodySm),
                ],
                const SizedBox(height: 10),
                SecondaryButton(
                  label: _cooldown > 0 ? 'Resend in ${_cooldown}s' : 'Resend code',
                  onPressed: (_sending || _cooldown > 0) ? null : () => _send(),
                ),
              ],
              const SizedBox(height: 4),
              TextButton(
                onPressed: _cancel,
                child: const Text('Use a different email'),
              ),
              const SizedBox(height: 8),
              Text(
                t.verifySpamHint,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
