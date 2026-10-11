import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../notifications/screens/notification_center_screen.dart';
import '../../settings/screens/logout_confirmation_screen.dart';
import 'edit_profile_screen.dart';
import 'saved_addresses_screen.dart';
import 'favorites_screen.dart';

/// "Account" tab — profile header, loyalty summary, contact info, and
/// settings list (matches the prototype's Account & Settings screen,
/// adapted for the customer role).
class CustomerProfileScreen extends StatelessWidget {
  const CustomerProfileScreen({super.key});

  /// 50 -> "50", 12.5 -> "12.50".
  static String _peso(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CustomerDataStore.instance,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final store = CustomerDataStore.instance;
    final unreadCount = CustomerDataStore.instance.notifications.where((n) => !n.read).length;
    final profile = CustomerDataStore.instance.profile;
    final email = AuthService.instance.currentFirebaseUser?.email ?? profile?.email ?? '';
    final name = (profile?.fullName.isNotEmpty ?? false)
        ? profile!.fullName
        : (AuthService.instance.currentProfile?.name ?? '—');
    final phone = profile?.phone ?? '';
    final points = CustomerDataStore.instance.pointsBalance;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';
    final fbUser = AuthService.instance.currentFirebaseUser;
    // A phone-sign-in account has no email; its identity was verified by SMS.
    final emailVerified =
        (fbUser?.emailVerified ?? false) || (fbUser?.phoneNumber ?? '').isNotEmpty;
    final addresses = CustomerDataStore.instance.addresses;
    final defaultAddress = CustomerDataStore.instance.defaultAddress;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Account & Settings'),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                tooltip: 'Notifications',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NotificationCenterScreen()),
                ),
              ),
              if (unreadCount > 0)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Loading / error (+ retry) for the account data. The details
            // below are real, so if they couldn't be loaded say so instead of
            // showing zero points / no addresses as if that were the truth.
            if (store.isLoading) const LinearProgressIndicator(minHeight: 2),
            if (store.error != null && !store.isLoading)
              StaleDataBanner(
                error: store.error!,
                leadIn: store.hasLoaded
                    ? 'Showing last saved data.'
                    : 'Some account details could not be loaded.',
                onRetry: () => store.retry(),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => store.refresh(),
                child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
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
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        initial,
                        style: AppTextStyles.headlineSm.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: AppTextStyles.titleMd),
                        Text('Kernel Member', style: AppTextStyles.bodySm),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    // The loyalty program has no tiers in the database, so none
                    // are invented here; the badge shows the real point balance.
                    child: Text(
                      '$points pts',
                      style: AppTextStyles.labelMd.copyWith(color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                boxShadow: AppShadows.sm,
              ),
              child: Row(
                children: [
                  const Icon(Icons.workspace_premium_rounded, color: AppColors.primaryDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Golden Kernel Rewards', style: AppTextStyles.titleMd),
                        Text(
                          store.earnPesosPerPoint == null
                              ? '$points pts • Earn rate not set yet'
                              : '$points pts • Earn 1 pt per ₱${_peso(store.earnPesosPerPoint!)} spent',
                          style: AppTextStyles.bodySm,
                        ),
                        // Points the database took back because an order was (partly) refunded.
                        Builder(builder: (context) {
                          final reversed = store.loyaltyTransactions
                              .where((t) => t.isRefundReversal)
                              .fold<int>(0, (sum, t) => sum + t.points);
                          return reversed > 0
                              ? Text('$reversed pts reversed by refunds', style: AppTextStyles.bodySm)
                              : const SizedBox.shrink();
                        }),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.pushNamed(context, '/customer/loyalty'),
                    child: const Text('Redeem'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Personal & Contact Info', style: AppTextStyles.titleMd),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: emailVerified ? AppColors.successBg : AppColors.warningBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          emailVerified ? 'Verified' : 'Email Not Verified',
                          style: AppTextStyles.labelSm.copyWith(
                            color: emailVerified ? AppColors.success : AppColors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  _FieldRow(label: 'FULL NAME', value: name.isEmpty ? 'Not set' : name),
                  _FieldRow(label: 'EMAIL', value: email.isEmpty ? 'Not set' : email),
                  _FieldRow(label: 'MOBILE NUMBER', value: phone.isEmpty ? 'Not set' : phone),
                  _FieldRow(
                    label: 'DELIVERY ADDRESS',
                    value: defaultAddress == null ? 'Not set' : defaultAddress.fullAddress,
                  ),
                  const SizedBox(height: 10),
                  SecondaryButton(
                    label: 'Edit Profile Information',
                    icon: Icons.edit_outlined,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const EditProfileScreen()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('SETTINGS', style: AppTextStyles.labelSm),
            const SizedBox(height: AppSpacing.xs),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Material(type: MaterialType.transparency, child: Column(
                children: [
                  _SettingsTile(
                    icon: Icons.settings_outlined,
                    title: 'App Settings',
                    subtitle: 'Preferences, branch, and more',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.appSettings),
                  ),
                  const Divider(height: 1),
                  _SettingsTile(
                    icon: Icons.shield_outlined,
                    title: 'Login & Security',
                    subtitle: 'Password, 2FA & active sessions',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.accountSecurity),
                  ),
                  const Divider(height: 1),
                  _SettingsTile(
                    icon: Icons.notifications_outlined,
                    title: 'Notification Preferences',
                    subtitle: 'Order updates & promos',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.notificationSettings),
                  ),
                  const Divider(height: 1),
                  _SettingsTile(
                    icon: Icons.location_on_outlined,
                    title: 'Saved Addresses',
                    subtitle: addresses.isEmpty
                        ? 'No address saved'
                        : '${addresses.length} address${addresses.length == 1 ? '' : 'es'} saved',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SavedAddressesScreen()),
                    ),
                  ),
                  const Divider(height: 1),
                  _SettingsTile(
                    icon: Icons.favorite_border_rounded,
                    title: 'Favourites',
                    subtitle: 'Products you saved',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FavoritesScreen()),
                    ),
                  ),                  const Divider(height: 1),
                  _SettingsTile(
                    icon: Icons.assignment_return_outlined,
                    title: 'Refund History',
                    subtitle: 'Track your refund requests',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.customerRefundHistory),
                  ),
                ],
              )),
            ),
            const SizedBox(height: AppSpacing.lg),
            SecondaryButton(
              label: 'Log Out of Session',
              icon: Icons.logout_rounded,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen()),
              ),
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

class _FieldRow extends StatelessWidget {
  final String label;
  final String value;

  const _FieldRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.labelSm),
          Text(value, style: AppTextStyles.bodyLg),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.darkBrown),
      title: Text(title, style: AppTextStyles.labelLg),
      subtitle: Text(subtitle, style: AppTextStyles.bodySm),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}
