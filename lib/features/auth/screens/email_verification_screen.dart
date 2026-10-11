import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/email_verification_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/user_role.dart';

/// Final step of customer sign-up: proves the person owns the email address.
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
  final bool _usesCode = EmailVerificationService.instance.usesCode;

  Timer? _timer;
  int _cooldown = 0;
  bool _sending = false;
  bool _verifying = false;

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

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = _cooldown > 0 ? _cooldown - 1 : 0);
      if (_cooldown == 0) t.cancel();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    if (_sending || _cooldown > 0) return;
    setState(() => _sending = true);
    try {
      await AuthService.instance.sendVerification();
      if (!mounted) return;
      _startCooldown();
      _toast(_usesCode ? 'A 6-digit code was sent to $_email.' : 'A verification link was sent to $_email.');
    } on AuthException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    if (_verifying) return;
    setState(() => _verifying = true);
    try {
      final user = await AuthService.instance.completeCustomerRegistration(
        // Keep digits only (ignores spaces/dashes people paste with the code).
        code: _usesCode ? _codeController.text.replaceAll(RegExp(r'\D'), '') : null,
      );
      if (!mounted) return;
      _toast('Welcome, ${user.name}! Your account is ready.');
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.homeFor(UserRole.customer),
        (r) => false,
      );
    } on AuthException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
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
                _usesCode
                    ? 'We sent a 6-digit code to $_email. Enter it below to finish creating your account.'
                    : 'We sent a verification link to $_email. Open the link, then come back and tap the button below.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_usesCode) ...[
                AppTextField(
                  label: 'Verification code',
                  controller: _codeController,
                  prefixIcon: Icons.pin_outlined,
                  keyboardType: TextInputType.number,
                  hint: '123456',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 4),
                const SizedBox(height: 12),
              ],
              PrimaryButton(
                label: _usesCode ? 'Verify & Create Account' : "I've verified my email",
                icon: Icons.verified_rounded,
                loading: _verifying,
                onPressed: _verify,
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                label: _cooldown > 0
                    ? 'Resend in ${_cooldown}s'
                    : (_usesCode ? 'Resend code' : 'Resend link'),
                onPressed: (_sending || _cooldown > 0) ? null : _send,
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _cancel,
                child: const Text('Use a different email'),
              ),
              const SizedBox(height: 8),
              Text(
                "Can't find it? Check your spam folder.",
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
