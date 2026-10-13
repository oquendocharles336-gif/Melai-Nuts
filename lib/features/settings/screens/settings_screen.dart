import 'package:flutter/material.dart';
import '../../../core/services/locale_controller.dart';
import '../../../core/services/staff_store.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../notifications/screens/notification_settings_screen.dart';
import 'security_screen.dart';
import 'branch_settings_screen.dart';
import 'logout_flow.dart';
import '../../../app/routes.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // There is no dark theme, so no dark-mode switch. Language: English or Filipino
  // (lib/l10n), saved on this device by LocaleController.

  Future<void> _pickLanguage() async {
    final t = AppLocalizations.of(context);
    final current = LocaleController.instance.value?.languageCode;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.language),
        children: [
          RadioGroup<String>(
            groupValue: current ?? '',
            onChanged: (v) => Navigator.of(ctx).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in <String, String>{
                  '': t.languageSystem,
                  'en': t.languageEnglish,
                  'fil': t.languageFilipino,
                }.entries)
                  RadioListTile<String>(value: entry.key, title: Text(entry.value)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await LocaleController.instance.select(picked.isEmpty ? null : picked);
  }

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
                  icon: Icons.translate_rounded,
                  title: AppLocalizations.of(context).language,
                  subtitle: AppLocalizations.of(context).languageSubtitle,
                  onTap: _pickLanguage,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _Section(
              children: [
                _Tile(
                  icon: Icons.admin_panel_settings_outlined,
                  title: AppLocalizations.of(context).permissionsTitle,
                  subtitle: AppLocalizations.of(context).permissionsSubtitle,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.appPermissions),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(AppLocalizations.of(context).legalSection, style: AppTextStyles.labelSm),
            const SizedBox(height: AppSpacing.xs),
            _Section(
              children: [
                _Tile(
                  icon: Icons.description_outlined,
                  title: AppLocalizations.of(context).legalTermsTitle,
                  subtitle: AppLocalizations.of(context).legalTermsSubtitle,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.legalTerms),
                ),
                const Divider(height: 1),
                _Tile(
                  icon: Icons.privacy_tip_outlined,
                  title: AppLocalizations.of(context).legalPrivacyTitle,
                  subtitle: AppLocalizations.of(context).legalPrivacySubtitle,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.legalPrivacy),
                ),
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
                  onTap: () => confirmAndLogOut(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Center(child: Text('Melai Nuts Retailing', style: AppTextStyles.bodySm)),
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