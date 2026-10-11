import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/info_banner.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/services/auth_service.dart';
import 'email_verification_screen.dart';

/// High-fidelity Account Registration screen.
/// Matches the "Warm Harvest Modern" design system.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _agreed = false;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (!_agreed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please agree to the Terms & Conditions')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      // Step 1: create the account. Step 2 (email verification, then profile
      // creation) happens on the verification screen.
      await AuthService.instance.startCustomerRegistration(
        name: _nameController.text,
        email: _emailController.text,
        phone: _phoneController.text,
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: AppColors.darkBrown),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const AppLogo(size: 80),
            const SizedBox(height: 16),
            Text(
              'Join Melai Nuts',
              textAlign: TextAlign.center,
              style: AppTextStyles.headlineLg.copyWith(color: AppColors.primary),
            ),
            const SizedBox(height: 8),
            Text(
              'Create an account to track your orders and earn Golden Kernel loyalty points.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd,
            ),
            const SizedBox(height: 24),
            Container(
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
                    AppTextField(
                      label: 'Full Name',
                      controller: _nameController,
                      prefixIcon: Icons.person_outline_rounded,
                      hint: 'Elena Santos',
                      validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      label: 'Email Address',
                      controller: _emailController,
                      prefixIcon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      hint: 'elena@example.com',
                      validator: ValidationUtils.validateEmail,
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      label: 'Mobile Number',
                      controller: _phoneController,
                      prefixIcon: Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                      hint: '09123456789',
                      validator: ValidationUtils.validatePhone,
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      label: 'Password',
                      controller: _passwordController,
                      prefixIcon: Icons.lock_outline_rounded,
                      obscure: true,
                      hint: '••••••••',
                      validator: ValidationUtils.validatePassword,
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      label: 'Confirm Password',
                      controller: _confirmPasswordController,
                      prefixIcon: Icons.lock_outline_rounded,
                      obscure: true,
                      hint: '••••••••',
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Please confirm your password.';
                        if (v != _passwordController.text) return 'Passwords do not match.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
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
                            'I agree to the Melai Nuts Laguna Terms of Service and Privacy Policy.',
                            style: AppTextStyles.bodySm,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    PrimaryButton(
                      label: 'Register Account',
                      icon: Icons.person_add_alt_1_rounded,
                      loading: _submitting,
                      onPressed: _register,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const InfoBanner(
              icon: Icons.stars_rounded,
              title: 'Loyalty Rewards',
              text: 'New members get 100 bonus points upon registration!',
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Already have an account?'),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Sign In'),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
