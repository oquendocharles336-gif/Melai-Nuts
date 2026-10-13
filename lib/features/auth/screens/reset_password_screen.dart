import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/password_strength_card.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';

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
  final _currentController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  bool _currentVisible = false;
  bool _passwordVisible = false;
  bool _confirmVisible = false;

  bool get _hasLength => _passwordController.text.length >= 8;
  // Same rules as ValidationUtils.validatePassword (shared helpers), so a
  // password the validator accepts — e.g. "Nuts+2026x" — is never blocked by a
  // stricter checklist here.
  bool get _hasUpper => ValidationUtils.hasUpper(_passwordController.text);
  bool get _hasNumber => ValidationUtils.hasDigit(_passwordController.text);
  bool get _hasSpecial => ValidationUtils.hasSpecial(_passwordController.text);
  int get _score =>
      [_hasLength, _hasUpper, _hasNumber, _hasSpecial].where((e) => e).length;
  bool get _match =>
      _passwordController.text.isNotEmpty &&
          _passwordController.text == _confirmController.text;

  bool get _canSubmit => _score == 4 && _match;

  Future<void> _resetPassword() async {
    if (_submitting || !FormUtils.validateAndFocus(_formKey)) return;
    if (!_canSubmit) {
      // Tell the person what is missing instead of silently doing nothing.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_missingRequirementsMessage())),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await AuthService.instance.changePassword(
        currentPassword: _currentController.text,
        newPassword: _passwordController.text,
      );
      if (!mounted) return;
      setState(() => _submitting = false);
      Navigator.of(context).pushReplacementNamed(AppRoutes.resetSuccess);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'reset_password_screen:56');
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  String _missingRequirementsMessage() {
    final missing = <String>[
      if (!_hasLength) 'at least 8 characters',
      if (!_hasUpper) 'an uppercase letter',
      if (!_hasNumber) 'a number',
      if (!_hasSpecial) 'a special character',
    ];
    if (missing.isNotEmpty) return 'Your new password needs ${missing.join(', ')}.';
    return 'Passwords do not match.';
  }

  void _onTextChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onTextChanged);
    _confirmController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onTextChanged);
    _confirmController.removeListener(_onTextChanged);
    _currentController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String get _accountEmail =>
      AuthService.instance.currentProfile?.email ??
      AuthService.instance.currentFirebaseUser?.email ??
      '';

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
              // Shows which account is being changed (replaces the old
              // "Step 2 of 2 / Authorized Node" placeholder, which had no step 1
              // and validated nothing).
              if (_accountEmail.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.sm,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.account_circle_outlined,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ACCOUNT', style: AppTextStyles.labelSm),
                            Text(
                              _accountEmail,
                              style: AppTextStyles.titleMd,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
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
              // Firebase needs a recent sign-in to change a password: the current
              // password re-confirms it (AuthService.changePassword).
              Text('Current Password', style: AppTextStyles.labelLg),
              const SizedBox(height: 6),
              TextFormField(
                controller: _currentController,
                obscureText: !_currentVisible,
                autofillHints: const [AutofillHints.password],
                maxLength: InputLimits.passwordMax,
                validator: (v) => (v == null || v.isEmpty) ? 'Please enter your current password.' : null,
                decoration: InputDecoration(
                  counterText: '',
                  prefixIcon: const Icon(
                    Icons.lock_clock_outlined,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  suffixIcon: IconButton(
                    tooltip: 'Show or hide password',
                    icon: Icon(
                      _currentVisible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () => setState(() => _currentVisible = !_currentVisible),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('New Password', style: AppTextStyles.labelLg),
              const SizedBox(height: 6),
              TextFormField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                autofillHints: const [AutofillHints.newPassword],
                maxLength: InputLimits.passwordMax,
                validator: (v) => ValidationUtils.validatePassword(
                  v,
                  email: AuthService.instance.currentFirebaseUser?.email,
                  name: AuthService.instance.currentProfile?.name,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  prefixIcon: const Icon(
                    Icons.key_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  suffixIcon: IconButton(tooltip: 'Show or hide password', 
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
                autofillHints: const [AutofillHints.newPassword],
                maxLength: InputLimits.passwordMax,
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Please confirm your new password.';
                  if (v != _passwordController.text) return 'Passwords do not match.';
                  return null;
                },
                decoration: InputDecoration(
                  counterText: '',
                  prefixIcon: const Icon(
                    Icons.lock_outline_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_match) const Icon(Icons.check_circle, color: AppColors.success),
                      IconButton(tooltip: 'Show or hide password', 
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
              PasswordStrengthCard(controller: _passwordController),
              const SizedBox(height: 20),
              PrimaryButton(
                label: 'Reset Password & Update Credentials',
                icon: Icons.arrow_forward_rounded,
                loading: _submitting,
                // Always tappable: field errors and the SnackBar in
                // _resetPassword explain what is missing, instead of a greyed-out
                // button with no reason given.
                onPressed: _resetPassword,
              ),
              const SizedBox(height: 10),
              // The person is signed in (opened from Settings → Security), and
              // /login is no longer on the stack after sign-in, so popUntil(login)
              // would pop every route and leave a black screen. Just go back.
              SecondaryButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
