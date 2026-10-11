import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/info_banner.dart';
import '../../../core/widgets/motion.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/utils/validation_utils.dart';
import 'email_verification_screen.dart';
import 'phone_login_screen.dart';
import '../../../data/models/user_role.dart';
/// Single sign-in / create-account screen shared by every account type
/// (customer, staff, owner, and delivery). One set of credentials, one
/// form — after signing in, the person is routed to whichever home screen
/// matches their role ([AppRoutes.homeFor]).
///
/// Self-service "Create Account" always creates a customer account; staff,
/// owner, and delivery accounts are provisioned by an owner/admin (see
/// Owner > User Management) and simply sign in here like anyone else.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  bool _isSignIn = true;
  bool _submitting = false;

  // Sign in
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _passwordVisible = false;

  // Create account (customer only)
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _agreed = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _newPasswordController.dispose();
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  Future<void> _createAccount() async {
    if (!_agreed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please agree to the Terms of Service')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      // Step 1 of sign-up; the verification screen completes it.
      await AuthService.instance.startCustomerRegistration(
        name: _nameController.text,
        email: _emailController.text,
        phone: _phoneController.text,
        password: _newPasswordController.text,
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      _openVerification();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isSignIn) {
      await _signIn();
    } else {
      await _createAccount();
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.primaryContainer, AppColors.surface, AppColors.canvas],
            stops: [0.0, 0.35, 0.7],
          ),
        ),
        child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          children: [
            const SizedBox(height: AppSpacing.md),
            FadeSlideIn(
              offsetY: 24,
              child: Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.22),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const AppLogo(size: 72),
              ),
            ),
            ),
            const SizedBox(height: AppSpacing.md),
            FadeSlideIn(
              delay: const Duration(milliseconds: 140),
              child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.md,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Text(
                      _isSignIn ? 'Welcome Back' : 'Create Your Account',
                      style: AppTextStyles.headlineLg.copyWith(
                        color: AppColors.darkBrown,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isSignIn
                          ? 'One account for shoppers, staff, owners, and\ndelivery riders — sign in to continue.'
                          : 'Create a customer account to order online and\nearn Golden Kernel loyalty points.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyMd,
                    ),
                    const SizedBox(height: AppSpacing.md),
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
                    const SizedBox(height: AppSpacing.md),
                    if (_isSignIn) ...[
                      AppTextField(
                        label: 'Email Address',
                        controller: _emailController,
                        prefixIcon: Icons.person_outline_rounded,
                        keyboardType: TextInputType.emailAddress,
                        validator: ValidationUtils.validateEmailFormat,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Password', style: AppTextStyles.labelLg),
                          TextButton(
                            onPressed: () => Navigator.of(
                              context,
                            ).pushNamed(AppRoutes.forgotPassword),
                            child: const Text('Forgot Password?'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: !_passwordVisible,
                        style: AppTextStyles.bodyLg,
                        validator: (v) => ValidationUtils.validateRequired(v, 'Password'),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _passwordVisible
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                              color: AppColors.textSecondary,
                            ),
                            onPressed: () =>
                                setState(() => _passwordVisible = !_passwordVisible),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      PrimaryButton(
                        label: 'Sign In',
                        icon: Icons.login_rounded,
                        loading: _submitting,
                        onPressed: _submit,
                      ),
                    ] else ...[
                      AppTextField(
                        label: 'Full Name',
                        controller: _nameController,
                        prefixIcon: Icons.person_outline_rounded,
                        validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
                      ),
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'Mobile Phone Number',
                        controller: _phoneController,
                        prefixIcon: Icons.phone_outlined,
                        keyboardType: TextInputType.phone,
                        helperText: 'Used for GCash & delivery rider SMS updates.',
                        validator: ValidationUtils.validatePhone,
                      ),
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'Email Address',
                        controller: _emailController,
                        prefixIcon: Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                        helperText: 'For digital receipts and pack batch tracking.',
                        validator: ValidationUtils.validateEmail,
                      ),
                      const SizedBox(height: 14),
                      AppTextField(
                        label: 'Password',
                        controller: _newPasswordController,
                        prefixIcon: Icons.lock_outline_rounded,
                        obscure: true,
                        validator: ValidationUtils.validatePassword,
                      ),
                      const SizedBox(height: 16),
                      const InfoBanner(
                        icon: Icons.contactless_rounded,
                        title: 'Physical RFID Member Card Support',
                        text:
                            'Have a Melai Nuts RFID Loyalty Card from Calamba, Los Baños, or Santa Cruz branches? You can link your physical card number during checkout or via in-store tap.',
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _agreed,
                            activeColor: AppColors.primary,
                            onChanged: (v) => setState(() => _agreed = v ?? false),
                          ),
                          Expanded(
                            child: Text(
                              'I agree to the Melai Nuts Laguna Customer Terms of Service and consent to receiving order tracking notifications via SMS.',
                              style: AppTextStyles.bodySm,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      PrimaryButton(
                        label: 'Create Account & Start Ordering',
                        icon: Icons.shopping_bag_outlined,
                        loading: _submitting,
                        onPressed: _submit,
                      ),
                    ],
                    if (_showPhoneLogin) ...[
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        children: [
                          const Expanded(child: Divider(color: AppColors.border)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('or', style: AppTextStyles.bodySm),
                          ),
                          const Expanded(child: Divider(color: AppColors.border)),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _submitting ? null : _openPhoneLogin,
                          icon: const Icon(Icons.phone_android_rounded, size: 18),
                          label: const Text('Log in with phone number'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: const BorderSide(color: AppColors.primary),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
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
