import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';

/// "Login & Security" — shows what Firebase Authentication actually knows
/// about the signed-in account (email, whether it is verified, how it signs
/// in, when it last signed in) and links to the real password-reset flow.
///
/// Nothing here is a stand-in: two-factor authentication, biometric login,
/// a supervisor PIN and remote sign-out of other devices are not implemented
/// by this app, so they are listed as unavailable rather than shown as
/// switches that do nothing.
class SecurityLoginScreen extends StatelessWidget {
  const SecurityLoginScreen({super.key});

  static String _providerLabel(String providerId) {
    switch (providerId) {
      case 'password':
        return 'Email & password';
      case 'google.com':
        return 'Google';
      case 'phone':
        return 'Phone number';
      default:
        return providerId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final providers = <String>{
      for (final p in user?.providerData ?? const <UserInfo>[]) _providerLabel(p.providerId),
    };
    final lastSignIn = user?.metadata.lastSignInTime;
    final usesPassword = user?.providerData.any((p) => p.providerId == 'password') ?? false;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Login & Security', showBack: true),
      body: SafeArea(
        child: user == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'You are not signed in.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMd,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Text('YOUR ACCOUNT', style: AppTextStyles.labelSm),
                  const SizedBox(height: AppSpacing.xs),
                  _Card(
                    children: [
                      _InfoRow(
                        icon: Icons.mail_outline_rounded,
                        label: 'Email',
                        value: (user.email ?? '').isEmpty ? 'No email on this account' : user.email!,
                      ),
                      const Divider(height: 24),
                      _InfoRow(
                        icon: user.emailVerified ? Icons.verified_outlined : Icons.warning_amber_rounded,
                        label: 'Email verification',
                        value: user.emailVerified ? 'Verified' : 'Not verified',
                        valueColor: user.emailVerified ? AppColors.success : AppColors.warning,
                      ),
                      const Divider(height: 24),
                      _InfoRow(
                        icon: Icons.login_rounded,
                        label: 'Sign-in method',
                        value: providers.isEmpty ? 'Unknown' : providers.join(', '),
                      ),
                      if (lastSignIn != null) ...[
                        const Divider(height: 24),
                        _InfoRow(
                          icon: Icons.schedule_rounded,
                          label: 'Last sign-in',
                          value: DateFormat('MMM d, y • h:mm a').format(lastSignIn.toLocal()),
                        ),
                      ],
                    ],
                  ),
                  if (usesPassword) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Text('PASSWORD', style: AppTextStyles.labelSm),
                    const SizedBox(height: AppSpacing.xs),
                    _Card(
                      children: [
                        InkWell(
                          onTap: () => Navigator.of(context).pushNamed(AppRoutes.resetPassword),
                          child: Row(
                            children: [
                              const Icon(Icons.vpn_key_rounded, color: AppColors.darkBrown),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Change password',
                                  style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Changing your password also signs you out on your other devices.',
                          style: AppTextStyles.bodySm,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Text('NOT AVAILABLE YET', style: AppTextStyles.labelSm),
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded, color: AppColors.textSecondary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Two-factor authentication, biometric login, a supervisor PIN and signing out '
                            'other devices remotely are not set up in this app, so they are not shown as '
                            'settings.',
                            style: AppTextStyles.bodyMd,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;

  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.darkBrown),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTextStyles.bodySm),
              const SizedBox(height: 2),
              Text(value, style: AppTextStyles.labelLg.copyWith(color: valueColor)),
            ],
          ),
        ),
      ],
    );
  }
}
