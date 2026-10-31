import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/page_transitions.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/form_utils.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'email_verification_screen.dart';
import 'phone_login_screen.dart';
import 'register_screen.dart';
import 'welcome_screen.dart';
import '../../../data/models/user_role.dart';
import '../../../core/utils/app_error.dart';

/// Single sign-in screen shared by every account type (customer, staff,
/// owner, and delivery). After signing in, the person is routed to whichever
/// home screen matches their role ([AppRoutes.homeFor]).
///
/// New customers use [RegisterScreen]; staff, owner, and delivery accounts
/// are provisioned by an owner/admin (see Owner > User Management) and simply
/// sign in here like anyone else.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _submitting = true);
    try {
      final user = await AuthService.instance.signIn(
        email: _emailController.text,
        password: _passwordController.text,
        allowVerificationResume: true,
      );

      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Signed in as ${user.name} (${user.role.label})')),
      );
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.homeFor(user.role), (r) => false);
    } on EmailVerificationRequiredException {
      // Signed up earlier but never finished verifying: resume.
      if (!mounted) return;
      setState(() => _submitting = false);
      _openVerification();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'login_screen:85');
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  Future<void> _submit() async {
    if (_submitting) return; // no double submit
    if (!FormUtils.validateAndFocus(_formKey)) return;
    await _signIn();
  }

  // Phone (SMS) sign-in is an Android-only extra; hidden everywhere else.
  bool get _showPhoneLogin => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _openPhoneLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PhoneLoginScreen()),
    );
  }

  void _openVerification() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
      (r) => r.settings.name == AppRoutes.splash,
    );
  }

  void _openRegister() {
    Navigator.of(context).pushReplacement(FadeSlideRoute(builder: (_) => const RegisterScreen()));
  }

  /// Sign-out lands here with nothing behind it: back then means Welcome.
  void _back() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(FadeSlideRoute(builder: (_) => const WelcomeScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LuxeAuthFrame(
      title: 'Welcome back',
      subtitle: 'One account for shoppers, staff, owners, and delivery riders.',
      onBack: _back,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTextField(
              label: 'Email Address',
              controller: _emailController,
              hint: 'you@example.com',
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              textInputAction: TextInputAction.next,
              maxLength: InputLimits.email,
              validator: ValidationUtils.validateEmailFormat,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              label: 'Password',
              controller: _passwordController,
              hint: 'Enter your password',
              obscure: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              maxLength: InputLimits.passwordMax,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => ValidationUtils.validateRequired(v, 'Password'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.forgotPassword),
                child: const Text('Forgot Password?'),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            PrimaryButton(label: 'Sign In', loading: _submitting, onPressed: _submit),
            if (_showPhoneLogin) ...[
              const SizedBox(height: AppSpacing.sm),
              SecondaryButton(
                label: 'Log in with phone number',
                icon: Icons.phone_android_rounded,
                onPressed: _submitting ? null : _openPhoneLogin,
              ),
            ],
            const Spacer(),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text("Don't have an account?", style: AppTextStyles.bodyMd),
                  TextButton(onPressed: _openRegister, child: const Text('Create Account')),
                ],
              ),
            ),
            const _LegalLinks(),
          ],
        ),
      ),
    );
  }
}

/// Terms and Privacy are readable at any time, also before signing in.
class _LegalLinks extends StatelessWidget {
  const _LegalLinks();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalTerms),
            child: Text(t.legalTermsTitle),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalPrivacy),
            child: Text(t.legalPrivacyTitle),
          ),
        ],
      ),
    );
  }
}
