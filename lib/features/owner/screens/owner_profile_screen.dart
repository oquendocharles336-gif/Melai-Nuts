import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../settings/screens/logout_confirmation_screen.dart';
import '../../settings/screens/settings_screen.dart';

/// Owner profile content — the "Profile" tab of the Owner Portal. Mirrors the
/// Staff profile pattern (avatar header, info card, settings list) and holds
/// the Log Out button. Has no Scaffold of its own so it can be used as a tab
/// body.
class OwnerProfileBody extends StatelessWidget {
  const OwnerProfileBody({super.key});

  @override
  Widget build(BuildContext context) {
    // The signed-in owner's own record (`staff_members`, via get_my_staff_context).
    return StaffDataScope(builder: (context, store) {
      final p = store.profile!;
      return _body(context, p.initials, p.fullName.isEmpty ? 'Owner' : p.fullName, p.email.isEmpty ? '—' : p.email,
          p.isActive ? 'Active' : 'Deactivated', store.activeBranchName.isEmpty ? '—' : store.activeBranchName);
    });
  }

  Widget _body(BuildContext context, String initials, String name, String email, String status, String viewing) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: AppColors.roleOwner,
                child: Text(
                  initials,
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              Text(name, style: AppTextStyles.headlineSm),
              Text('Business Owner', style: AppTextStyles.bodyMd),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileItem(icon: Icons.mail_outline_rounded, title: 'Email', value: email),
              const Divider(height: 24),
              const _ProfileItem(icon: Icons.storefront_outlined, title: 'Branch Access', value: 'All branches'),
              const Divider(height: 24),
              _ProfileItem(icon: Icons.visibility_outlined, title: 'Viewing branch', value: viewing),
              const Divider(height: 24),
              _ProfileItem(icon: Icons.verified_user_outlined, title: 'Account status', value: status),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Material(type: MaterialType.transparency, child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.settings_outlined, color: AppColors.darkBrown),
                title: Text('App Settings', style: AppTextStyles.labelLg),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          )),
        ),
        const SizedBox(height: AppSpacing.lg),
        SecondaryButton(
          label: 'Log Out',
          icon: Icons.logout_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen()),
          ),
        ),
      ],
    );
  }
}

class _ProfileItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  const _ProfileItem({required this.icon, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.bodySm),
              Text(value, style: AppTextStyles.labelLg),
            ],
          ),
        ),
      ],
    );
  }
}