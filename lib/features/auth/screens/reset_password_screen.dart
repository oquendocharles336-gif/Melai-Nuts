import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/services/auth_service.dart';

/// Change the current user's password (used from Login & Security), with a
/// live strength checklist. Requires the person to already be signed in and
/// recently authenticated — for a locked-out user, see
/// [ForgotPasswordScreen] instead, which emails a reset link.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  bool _passwordVisible = false;
  bool _confirmVisible = false;

  bool get _hasLength => _passwordController.text.length >= 8;
  bool get _hasUpper => _passwordController.text.contains(RegExp(r'[A-Z]'));
  bool get _hasNumber => _passwordController.text.contains(RegExp(r'[0-9]'));
  bool get _hasSpecial =>
      _passwordController.text.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_]'));
  int get _score =>
      [_hasLength, _hasUpper, _hasNumber, _hasSpecial].where((e) => e).length;
  bool get _match =>
      _passwordController.text.isNotEmpty &&
          _passwordController.text == _confirmController.text;

  bool get _canSubmit => _score == 4 && _match;

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_canSubmit) return;
    setState(() => _submitting = true);
    try {
      await AuthService.instance.changePassword(_passwordController.text);
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pushReplacementNamed(AppRoutes.resetSuccess);
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
  void initState() {
    super.initState();
    _passwordController.addListener(() => setState(() {}));
    _confirmController.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Melai Nuts Retailing', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'STEP 2 OF 2 • SECURITY ACCESS',
                        style: AppTextStyles.labelSm,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('AUTHORIZED NODE', style: AppTextStyles.labelSm),
                        Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              size: 14,
                              color: AppColors.success,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Valid',
                              style: AppTextStyles.labelMd.copyWith(
                                color: AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('Authorized Access Node', style: AppTextStyles.titleMd),
                    Text(
                      'Laguna Branch Portal',
                      style: AppTextStyles.bodySm,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Create New Password', style: AppTextStyles.headlineMd),
              const SizedBox(height: 4),
              Text(
                'Choose a strong password for your Melai Nuts portal account.',
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: 16),
              Text('New Password', style: AppTextStyles.labelLg),
              const SizedBox(height: 6),
              TextFormField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                decoration: InputDecoration(
                  prefixIcon: const Icon(
                    Icons.key_rounded,
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
                    onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('Confirm New Password', style: AppTextStyles.labelLg),
              const SizedBox(height: 6),
              TextFormField(
                controller: _confirmController,
                obscureText: !_confirmVisible,
                decoration: InputDecoration(
                  prefixIcon: const Icon(
                    Icons.lock_outline_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_match) const Icon(Icons.check_circle, color: AppColors.success),
                      IconButton(
                        icon: Icon(
                          _confirmVisible
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => setState(() => _confirmVisible = !_confirmVisible),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Password Strength Check', style: AppTextStyles.labelLg),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _score == 4
                                ? AppColors.successBg
                                : AppColors.warningBg,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _score == 4
                                ? 'Strong ($_score/4)'
                                : 'Weak ($_score/4)',
                            style: AppTextStyles.labelMd.copyWith(
                              color: _score == 4
                                  ? AppColors.success
                                  : AppColors.warning,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _CheckRow(ok: _hasLength, label: 'At least 8 characters'),
                    _CheckRow(ok: _hasUpper, label: 'At least 1 uppercase letter (A-Z)'),
                    _CheckRow(ok: _hasNumber, label: 'At least 1 number (0-9)'),
                    _CheckRow(
                      ok: _hasSpecial,
                      label: 'At least 1 special character (!@#\$_)',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: 'Reset Password & Update Credentials',
                icon: Icons.arrow_forward_rounded,
                loading: _submitting,
                onPressed: _canSubmit ? _resetPassword : null,
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'Cancel and Return to Login',
                onPressed: () => Navigator.of(
                  context,
                ).popUntil((r) => r.settings.name == AppRoutes.login),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool ok;
  final String label;
  const _CheckRow({required this.ok, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? AppColors.success : AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppTextStyles.bodyMd.copyWith(
              color: ok ? AppColors.success : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}