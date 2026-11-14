import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/services/legal_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../legal/widgets/terms_consent_field.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/info_banner.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/person_name.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/person_name_fields.dart';
import '../../../core/widgets/page_transitions.dart';
import '../../../core/widgets/password_strength_card.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/services/auth_service.dart';
import 'email_verification_screen.dart';
import 'login_screen.dart';
import 'welcome_screen.dart';
import '../../../core/utils/app_error.dart';

/// Customer account registration. Staff, owner, and delivery accounts are
/// provisioned by an owner/admin instead (see [LoginScreen]).
class RegisterScreen extends StatefulWidget {
  /// Opened from Sign In, which is still underneath.
  final bool fromSignIn;

  const RegisterScreen({super.key, this.fromSignIn = false});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  // Consent starts unticked: agreeing is an active choice.
  bool _agreed = false;
  bool _orderUpdates = false;
  bool _submitting = false;

  // The Password rules look at the email and name, so it re-validates when they change.
  late final Listenable _passwordDeps =
      Listenable.merge([_emailController, _firstNameController, _lastNameController]);

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// The one name value the account stores.
  String get _fullName => PersonName(
        first: _firstNameController.text,
        last: _lastNameController.text,
      ).fullName;

  Future<void> _register() async {
    if (_submitting) return; // no double submit
    // Shows each message under its field (consent included) and focuses the
    // first invalid one.
    if (!FormUtils.validateAndFocus(_formKey) || !_agreed) return;

    setState(() => _submitting = true);
    // Recorded for this account on its first signed-in screen (LegalService).
    LegalService.instance.markConsentGiven(orderUpdates: _orderUpdates);
    try {
      // Step 1: create the account. Step 2 (email verification, then profile
      // creation) happens on the verification screen.
      await AuthService.instance.startCustomerRegistration(
        name: _fullName,
        email: _emailController.text,
        phone: ValidationUtils.normalizePhone(_phoneController.text),
        password: _passwordController.text,
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
        (r) => r.settings.name == AppRoutes.splash,
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'register_screen:73');
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  void _openSignIn() {
    if (widget.fromSignIn) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      FadeSlideRoute(
        settings: const RouteSettings(name: AppRoutes.login),
        builder: (_) => const LoginScreen(),
      ),
    );
  }

  /// With nothing behind this screen, back means Welcome.
  void _back() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacement(FadeSlideRoute(builder: (_) => const WelcomeScreen()));
    }
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(
          children: [
            Text(text.toUpperCase(), style: AppTextStyles.labelSm.copyWith(color: AppColors.primary, letterSpacing: 1.6)),
            const SizedBox(width: AppSpacing.sm),
            const Expanded(child: Divider(height: 1)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LuxeAuthFrame(
      title: 'Create your account',
      subtitle: 'Order online, track your orders and earn Golden Kernel loyalty points.',
      onBack: _back,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('About you'),
            PersonNameFields(
              first: _firstNameController,
              last: _lastNameController,
              liveValidate: true,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              label: 'Mobile Number',
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              textInputAction: TextInputAction.next,
              inputFormatters: InputRules.phone(),
              liveValidate: true,
              hint: '09171234567',
              helperText: '11 digits. Used for order updates.',
              validator: ValidationUtils.validateMobile,
            ),
            const SizedBox(height: AppSpacing.lg),
            _sectionLabel('Sign-in details'),
            AppTextField(
              label: 'Email Address',
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              maxLength: InputLimits.email,
              liveValidate: true,
              hint: 'you@example.com',
              helperText: 'Used to sign in and to verify your account.',
              validator: ValidationUtils.validateEmail,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              label: 'Password',
              controller: _passwordController,
              obscure: true,
              hint: 'Create a password',
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              maxLength: InputLimits.passwordMax,
              liveValidate: true,
              revalidateOn: _passwordDeps,
              validator: (v) => ValidationUtils.validatePassword(
                v,
                email: _emailController.text,
                name: _fullName,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Live checklist of the password rules (same rules as the validator above).
            PasswordStrengthCard(controller: _passwordController),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              label: 'Confirm Password',
              controller: _confirmPasswordController,
              obscure: true,
              hint: 'Enter it again',
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              maxLength: InputLimits.passwordMax,
              liveValidate: true,
              revalidateOn: _passwordController,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Please confirm your password.';
                if (v != _passwordController.text) return 'Passwords do not match.';
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            const InfoBanner(
              icon: Icons.contactless_rounded,
              title: 'Physical RFID Member Card Support',
              text:
                  'Have a Melai Nuts RFID loyalty card? Branch staff can link it to your account when you tap it at the counter.',
            ),
            const SizedBox(height: AppSpacing.md),
            TermsConsentField(initialValue: _agreed, onChanged: (v) => _agreed = v),
            OptionalConsentTile(
              value: _orderUpdates,
              label: AppLocalizations.of(context).consentOrderUpdates,
              onChanged: (v) => setState(() => _orderUpdates = v),
            ),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(
              label: 'Create Account',
              loading: _submitting,
              onPressed: _register,
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Already have an account?', style: AppTextStyles.bodyMd),
                  TextButton(onPressed: _openSignIn, child: const Text('Sign In')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
