import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/validation_utils.dart';

/// Live "Password Strength Check" card: four rules with a tick each and a
/// Strong / Weak (n/4) badge. It listens to [controller] itself, so the screen
/// using it does not need to rebuild on every keystroke.
///
/// The rules are the same helpers [ValidationUtils.validatePassword] uses, so a
/// password this card shows as Strong is never refused by the form, and the
/// other way round. Used by customer sign-up and by Change Password.
class PasswordStrengthCard extends StatelessWidget {
  final TextEditingController controller;

  const PasswordStrengthCard({super.key, required this.controller});

  /// How many of the four rules [password] meets (0-4).
  static int score(String password) => [
        password.length >= InputLimits.passwordMin,
        ValidationUtils.hasUpper(password),
        ValidationUtils.hasDigit(password),
        ValidationUtils.hasSpecial(password),
      ].where((ok) => ok).length;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final p = value.text;
        final hasLength = p.length >= InputLimits.passwordMin;
        final hasUpper = ValidationUtils.hasUpper(p);
        final hasNumber = ValidationUtils.hasDigit(p);
        final hasSpecial = ValidationUtils.hasSpecial(p);
        final n = score(p);
        final strong = n == 4;

        return Container(
          width: double.infinity,
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
                  Flexible(child: Text('Password Strength Check', style: AppTextStyles.labelLg)),
                  Semantics(
                    label: 'Password strength ${strong ? 'strong' : 'weak'}, $n of 4 rules met',
                    excludeSemantics: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: strong ? AppColors.successBg : AppColors.warningBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        strong ? 'Strong ($n/4)' : 'Weak ($n/4)',
                        style: AppTextStyles.labelMd.copyWith(
                          color: strong ? AppColors.success : AppColors.warning,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _CheckRow(ok: hasLength, label: 'At least ${InputLimits.passwordMin} characters'),
              _CheckRow(ok: hasUpper, label: 'At least 1 uppercase letter (A-Z)'),
              _CheckRow(ok: hasNumber, label: 'At least 1 number (0-9)'),
              _CheckRow(ok: hasSpecial, label: 'At least 1 special character (!@#\$_)'),
            ],
          ),
        );
      },
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool ok;
  final String label;
  const _CheckRow({required this.ok, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: ${ok ? 'done' : 'not yet'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(
              ok ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: ok ? AppColors.success : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: AppTextStyles.bodyMd.copyWith(
                  color: ok ? AppColors.success : AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
