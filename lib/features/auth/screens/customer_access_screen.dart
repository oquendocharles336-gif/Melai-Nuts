import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
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
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/services/auth_service.dart';
import '../../../data/models/user_role.dart';
import 'email_verification_screen.dart';
import '../../../core/utils/app_error.dart';

/// Customer sign-in / create-account screen (RFID loyalty ordering portal).
class CustomerAccessScreen extends StatefulWidget {
  const CustomerAccessScreen({super.key});

  @override
  State<CustomerAccessScreen> createState() => _CustomerAccessScreenState();
}

class _CustomerAccessScreenState extends State<CustomerAccessScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isSignIn = true;
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  // Consent is never pre-ticked; order updates is a separate, optional choice.
  bool _agreed = false;
  bool _orderUpdates = false;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_submitting) return; // no double submit
    // Field messages (and the consent message) appear under each field; the
    // first invalid field is focused.
    if (!FormUtils.validateAndFocus(_formKey)) return;
    if (!_isSignIn && !_agreed) return;

    setState(() => _submitting = true);
    try {
      if (!_isSignIn) {
        LegalService.instance.markConsentGiven(orderUpdates: _orderUpdates);
        // Step 1 of sign-up; the verification screen completes it.
        await AuthService.instance.startCustomerRegistration(
          name: _nameController.text,
          email: _emailController.text,
          phone: ValidationUtils.normalizePhone(_phoneController.text),
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() => _submitting = false);
        _openVerification();
        return;
      }

      final user = await AuthService.instance.signIn(
        email: _emailController.text,
        password: _passwordController.text,
        allowVerificationResume: true,
      );

      if (user.role != UserRole.customer) {
        // A staff/owner/delivery email typed into the customer portal.
        await AuthService.instance.signOut();
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This account is not a customer account. Use the staff/owner/'
              'delivery sign-in instead.',
            ),
          ),
        );
        return;
      }

      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Welcome, ${user.name}!')),
      );
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.homeFor(UserRole.customer), (r) => false);
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
      AppErrors.report(caughtError, caughtStack, 'customer_access_screen:98');
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  void _openVerification() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const EmailVerificationScreen()),
      (r) => r.settings.name == AppRoutes.splash,
    );
  }

  Future<void> _guestAccess() async {
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.homeFor(UserRole.customer), (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Melai Nuts Retailing',
        showBack: true,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: Icon(Icons.swap_horiz_rounded, color: AppColors.darkBrown),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.md,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CUSTOMER ORDERING PORTAL',
                      style: AppTextStyles.labelSm,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isSignIn ? 'Sign In' : 'Create Customer Account',
                      style: AppTextStyles.headlineMd,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Sign in or sign up to see live stock at your branch and check out quickly.',
                      style: AppTextStyles.bodyMd,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ToggleTab(
                              label: 'Sign In',
                              icon: Icons.login_rounded,
                              selected: _isSignIn,
                              onTap: () => setState(() => _isSignIn = true),
                            ),
                          ),
                          Expanded(
                            child: _ToggleTab(
                              label: 'Create Account',
                              icon: Icons.person_add_alt_1_rounded,
                              selected: !_isSignIn,
                              onTap: () => setState(() => _isSignIn = false),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!_isSignIn) ...[
                      AppTextField(
                        label: 'Full Name',
                        controller: _nameController,
                        prefixIcon: Icons.person_outline_rounded,
                        keyboardType: TextInputType.name,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                        maxLength: InputLimits.name,
                        validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
                      ),
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'Mobile Phone Number',
                        controller: _phoneController,
                        prefixIcon: Icons.phone_outlined,
                        keyboardType: TextInputType.phone,
                        autofillHints: const [AutofillHints.telephoneNumber],
                        textInputAction: TextInputAction.next,
                        inputFormatters: InputRules.phone(),
                        hint: '0917 123 4567',
                        helperText: 'Used by the rider to reach you about a delivery.',
                        validator: ValidationUtils.validatePhone,
                      ),
                      const SizedBox(height: 14),
                    ],
                    AppTextField(
                      label: 'Email Address',
                      controller: _emailController,
                      prefixIcon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      maxLength: InputLimits.email,
                      helperText: _isSignIn
                          ? null
                          : 'Used to sign in and to verify your account.',
                      // Sign-in: format only (existing accounts). Sign-up: also catch typos.
                      validator: _isSignIn
                          ? ValidationUtils.validateEmailFormat
                          : ValidationUtils.validateEmail,
                    ),
                    const SizedBox(height: 14),
                    AppTextField(
                      label: 'Password',
                      controller: _passwordController,
                      prefixIcon: Icons.lock_outline_rounded,
                      obscure: true,
                      autofillHints: [_isSignIn ? AutofillHints.password : AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      maxLength: InputLimits.passwordMax,
                      validator: (v) => _isSignIn
                          ? ValidationUtils.validateRequired(v, 'Password')
                          : ValidationUtils.validatePassword(
                              v,
                              email: _emailController.text,
                              name: _nameController.text,
                            ),
                    ),
                    const SizedBox(height: 16),
                    const InfoBanner(
                      icon: Icons.contactless_rounded,
                      title: 'Physical RFID Member Card Support',
                      text:
                          'Have a Melai Nuts RFID loyalty card? Branch staff can link it to your account when you tap it at the counter.',
                    ),
                    const SizedBox(height: 14),
                    if (!_isSignIn) ...[
                      TermsConsentField(initialValue: _agreed, onChanged: (v) => _agreed = v),
                      OptionalConsentTile(
                        value: _orderUpdates,
                        label: AppLocalizations.of(context).consentOrderUpdates,
                        onChanged: (v) => setState(() => _orderUpdates = v),
                      ),
                    ],
                    const SizedBox(height: 6),
                    PrimaryButton(
                      label: _isSignIn
                          ? 'Sign In & Start Ordering'
                          : 'Create Customer Account & Start Ordering',
                      icon: _isSignIn
                          ? Icons.login_rounded
                          : Icons.shopping_bag_outlined,
                      loading: _submitting,
                      onPressed: _continue,
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        onPressed: () => setState(() => _isSignIn = !_isSignIn),
                        child: Text(
                          _isSignIn
                              ? "Don't have an account? Create one"
                              : 'Already have an account? Sign In',
                        ),
                      ),
                    ),
                    Center(
                      child: TextButton(
                        onPressed: _guestAccess,
                        child: const Text('Browse Catalog as Guest →'),
                      ),
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalTerms),
                          child: Text(AppLocalizations.of(context).legalTermsTitle),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalPrivacy),
                          child: Text(AppLocalizations.of(context).legalPrivacyTitle),
                        ),
                      ],
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

class _ToggleTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.darkBrown.withValues(alpha: 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppTextStyles.labelLg.copyWith(
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
