import 'package:flutter/material.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../notifications/screens/notification_settings_screen.dart';
import 'security_screen.dart';
import 'branch_settings_screen.dart';
import 'logout_confirmation_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Dark mode and language switches were removed: the app has no dark theme
  // or translations, so those switches changed nothing.

  @override
  Widget build(BuildContext context) {
    // Staff accounts: notification preferences and the preferred-branch picker
    // are customer features (staff notifications follow their assigned branch,
    // which only the owner can change), so they are not offered here.
    final isStaff = StaffStore.instance.profile != null;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Settings', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (!isStaff) ...[
            Text('PREFERENCES', style: AppTextStyles.labelSm),
              const SizedBox(height: AppSpacing.xs),
              _Section(
                children: [
                  _Tile(
                    icon: Icons.notifications_outlined,
                    title: 'Notification Settings',
                    subtitle: 'Manage what you get notified about',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            Text('ACCOUNT', style: AppTextStyles.labelSm),
            const SizedBox(height: AppSpacing.xs),
            _Section(
              children: [
                _Tile(
                  icon: Icons.shield_outlined,
                  title: 'Account Security',
                  subtitle: 'Password and sign-in',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SecurityScreen()),
                  ),
                ),
                if (!isStaff) ...[
                  const Divider(height: 1),
                  _Tile(
                    icon: Icons.storefront_outlined,
                    title: 'Branch Settings',
                    subtitle: 'Set your preferred branch',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BranchSettingsScreen()),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _Section(
              children: [
                _Tile(
                  icon: Icons.logout_rounded,
                  title: 'Log Out',
                  subtitle: 'Sign out of this device',
                  iconColor: AppColors.error,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Center(child: Text('Melai Nuts Retailing • v1.0.0', style: AppTextStyles.bodySm)),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final List<Widget> children;

  const _Section({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Material(type: MaterialType.transparency, child: Column(children: children)),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? iconColor;

  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AppColors.darkBrown),
      title: Text(title, style: AppTextStyles.labelLg.copyWith(color: iconColor)),
      subtitle: Text(subtitle, style: AppTextStyles.bodySm),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
