import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/staff_models.dart';
import '../../settings/screens/logout_flow.dart';
import '../../settings/screens/settings_screen.dart';
import '../widgets/staff_avatar.dart';

/// Staff notifications, read from the database (`staff_notifications`).
/// A person only ever receives their own: new orders at their branch, low /
/// out-of-stock alerts, stock transfers and (with permission) refund requests.
class StaffNotificationsScreen extends StatelessWidget {
  const StaffNotificationsScreen({super.key});

  static IconData _icon(String category) {
    switch (category) {
      case 'order':
        return Icons.receipt_long_rounded;
      case 'inventory':
        return Icons.inventory_2_outlined;
      case 'transfer':
        return Icons.sync_alt_rounded;
      case 'refund':
        return Icons.assignment_return_outlined;
      default:
        return Icons.notifications_none_rounded;
    }
  }

  static Color _color(String category) {
    switch (category) {
      case 'inventory':
        return AppColors.warning;
      case 'refund':
        return AppColors.error;
      case 'transfer':
        return AppColors.roleStaff;
      default:
        return AppColors.primary;
    }
  }

  void _open(BuildContext context, StaffStore store, StaffNotification n) {
    if (!n.read) store.markNotificationRead(n.id);
    final nav = Navigator.of(context);
    switch (n.category) {
      case 'inventory':
        nav.pushNamed(AppRoutes.inventoryLowStock);
        break;
      case 'transfer':
        nav.pushNamed(AppRoutes.inventoryTransfers);
        break;
      case 'refund':
        if (store.canReviewRefunds) nav.pushNamed(AppRoutes.staffRefunds);
        break;
      case 'order':
        final id = n.reference;
        if (id == null) break;
        for (final o in store.orders) {
          if (o.id == id) {
            nav.pushNamed(AppRoutes.staffTransactionDetails, arguments: o);
            break;
          }
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final items = store.notifications;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: MelaiAppBar(
            title: 'Notifications',
            showBack: true,
            actions: [
              if (store.unreadNotifications > 0)
                TextButton(onPressed: store.markAllNotificationsRead, child: const Text('Mark all read')),
            ],
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshNotifications,
              child: DataStateView(
                isLoading: store.notificationsState.busy,
                error: store.notificationsState.error,
                isEmpty: items.isEmpty,
                onRetry: store.refreshNotifications,
                emptyIcon: Icons.notifications_none_rounded,
                emptyTitle: 'No notifications yet.',
                emptyMessage: 'New orders, stock alerts and transfers will show up here.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: items.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final n = items[i];
                    final color = _color(n.category);
                    return Dismissible(
                      key: ValueKey(n.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(AppSpacing.radiusMd)),
                        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                      ),
                      // Ask first: a swipe can be accidental.
                      confirmDismiss: (_) => ConfirmDialog.delete(context, '"${n.title}"'),
                      onDismissed: (_) => store.deleteNotification(n.id),
                      child: InkWell(
                        onTap: () => _open(context, store, n),
                        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: n.read ? Colors.white : AppColors.primaryContainer.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppShadows.sm,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                                child: Icon(_icon(n.category), color: color, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(n.title, style: AppTextStyles.labelLg),
                                    const SizedBox(height: 2),
                                    Text(n.body, style: AppTextStyles.bodySm),
                                    const SizedBox(height: 4),
                                    Text(friendlyTime(n.createdAt), style: AppTextStyles.labelSm),
                                  ],
                                ),
                              ),
                              if (!n.read)
                                Container(
                                  width: 8,
                                  height: 8,
                                  margin: const EdgeInsets.only(top: 6),
                                  decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Standalone Staff profile page (kept so the `/staff/profile` route still
/// works). The actual content lives in [StaffProfileBody], which is also
/// embedded as the "Profile" tab in the Staff Portal bottom navigation.
class StaffProfileScreen extends StatelessWidget {
  const StaffProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Staff Profile', showBack: true),
      body: SafeArea(child: StaffProfileBody()),
    );
  }
}

/// Staff profile: the signed-in account exactly as the database knows it —
/// name, email, role, assigned branch, status and permissions. Internal ids
/// (such as the account UID) are deliberately not shown.
class StaffProfileBody extends StatelessWidget {
  const StaffProfileBody({super.key});

  String _memberSince(DateTime d) {
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final p = store.profile!;
        return RefreshIndicator(
          onRefresh: store.start,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd],
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                  boxShadow: AppShadows.md,
                ),
                child: CustomPaint(
                  painter: LatticePainter(color: Colors.white.withValues(alpha: 0.07)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        children: [
                          Semantics(
                            button: true,
                            label: 'Change profile picture',
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => changeStaffPhoto(context),
                              child: Stack(
                                children: [
                                  StaffAvatar(profile: p, size: 104),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: AppColors.honey,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                      ),
                                      child: const Icon(Icons.photo_camera_rounded, size: 17, color: AppColors.ink),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            p.fullName.isEmpty ? 'Staff member' : p.fullName,
                            textAlign: TextAlign.center,
                            style: AppTextStyles.headlineMd.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            store.activeBranchName.isEmpty ? p.roleLabel : '${p.roleLabel} • ${store.activeBranchName}',
                            textAlign: TextAlign.center,
                            style: AppTextStyles.bodyMd.copyWith(color: AppColors.gold),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                    _ProfileItem(icon: Icons.email_outlined, title: 'Email', value: p.email.isEmpty ? '—' : p.email),
                    const Divider(height: 24),
                    _ProfileItem(icon: Icons.badge_outlined, title: 'Role', value: p.roleLabel),
                    const Divider(height: 24),
                    _ProfileItem(
                      icon: Icons.storefront_outlined,
                      title: p.isOwner ? 'Viewing branch' : 'Assigned branch',
                      value: store.activeBranchName.isEmpty ? '—' : store.activeBranchName,
                    ),
                    const Divider(height: 24),
                    _ProfileItem(
                      icon: Icons.verified_user_outlined,
                      title: 'Account status',
                      value: p.isActive ? 'Active' : 'Deactivated',
                    ),
                    const Divider(height: 24),
                    _ProfileItem(
                      icon: Icons.lock_open_rounded,
                      title: 'Permissions',
                      value: [
                        'Register & orders',
                        if (p.canManageInventory) 'Inventory',
                        if (p.canReviewRefunds) 'Refunds',
                        if (p.isOwner) 'All branches',
                      ].join(' • '),
                    ),
                    if (p.createdAt != null) ...[
                      const Divider(height: 24),
                      _ProfileItem(icon: Icons.calendar_today_rounded, title: 'Member since', value: _memberSince(p.createdAt!)),
                    ],
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
                    if (p.isOwner || p.canReviewRefunds) ...[
                      ListTile(
                        leading: const Icon(Icons.assignment_return_outlined, color: AppColors.darkBrown),
                        title: Text('Refund Requests', style: AppTextStyles.labelLg),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).pushNamed(AppRoutes.staffRefunds),
                      ),
                      const Divider(height: 1),
                    ],
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
              const LogOutButton(),
            ],
          ),
        );
      },
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
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: AppColors.roleStaff.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 19, color: AppColors.roleStaff),
        ),
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
