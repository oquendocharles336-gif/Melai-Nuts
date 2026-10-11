import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/repositories/notifications_repository.dart';
import '../../../core/services/pending_writes_service.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  bool _pushEnabled = true;
  bool _orderUpdates = true;
  bool _deliveryUpdates = true;
  bool _loyaltyUpdates = true;
  bool _promos = false;
  bool _systemAnnouncements = true;
  bool _emailNotifications = false;
  bool _smsNotifications = false;
  bool _saving = false;
  bool _loadingPrefs = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final uid = AuthService.instance.currentFirebaseUser?.uid;
    if (uid == null) {
      setState(() => _loadingPrefs = false);
      return;
    }
    setState(() {
      _loadingPrefs = true;
      _loadError = null;
    });
    try {
      final prefs = await AppErrors.guard(
        () => NotificationsRepository.instance.fetchPreferences(uid),
      );
      if (!mounted) return;
      if (prefs == null) {
        // No saved preferences yet: the defaults on screen are the truth.
        setState(() => _loadingPrefs = false);
        return;
      }
      // Unsynced local choices win over what the server still has, so the
      // screen never shows a stale value the person already changed.
      final unsynced = PendingWritesService.instance.pendingPreferences(uid);
      setState(() {
        _loadingPrefs = false;
        _orderUpdates = unsynced?['order_updates'] ?? (prefs['order_updates'] as bool?) ?? _orderUpdates;
        _deliveryUpdates = unsynced?['delivery_updates'] ?? (prefs['delivery_updates'] as bool?) ?? _deliveryUpdates;
        _loyaltyUpdates = unsynced?['loyalty_updates'] ?? (prefs['loyalty_updates'] as bool?) ?? _loyaltyUpdates;
        _promos = unsynced?['promos'] ?? (prefs['promos'] as bool?) ?? _promos;
      });
    } catch (e) {
      // Saving now would overwrite the customer's real preferences with
      // defaults, so block Save and offer a retry instead.
      if (!mounted) return;
      setState(() {
        _loadingPrefs = false;
        _loadError = e;
      });
    }
  }

  Future<void> _save() async {
    final uid = AuthService.instance.currentFirebaseUser?.uid;
    if (uid == null) return;
    setState(() => _saving = true);
    try {
      final outcome = await PendingWritesService.instance.run(
        uid,
        PendingWriteKind.notificationPreferences,
        {
          'prefs': {
            'order_updates': _orderUpdates,
            'delivery_updates': _deliveryUpdates,
            'loyalty_updates': _loyaltyUpdates,
            'promos': _promos,
          },
        },
      );
      if (!mounted) return;
      switch (outcome.kind) {
        case WriteOutcomeKind.synced:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notification preferences saved.')),
          );
          Navigator.of(context).pop();
        case WriteOutcomeKind.queued:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved on this device only — not on your account yet. It will sync automatically when the server is reachable.'),
              duration: Duration(seconds: 5),
            ),
          );
          Navigator.of(context).pop();
        case WriteOutcomeKind.rejected:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save preferences: ${outcome.message ?? 'the server refused it'}')),
          );
      }
    } catch (e) {
      if (!mounted) return;
      AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Notification Settings', showBack: true),
      body: SafeArea(
        child: _loadingPrefs
            ? const StateLoadingView(message: 'Loading your preferences...')
            : _loadError != null
                ? StateErrorView(
                    error: _loadError,
                    message: 'We couldn\'t load your notification preferences.',
                    onRetry: _loadPreferences,
                  )
                : ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _SectionCard(
              children: [
                _ToggleTile(
                  icon: Icons.notifications_active_rounded,
                  title: 'Push Notifications',
                  subtitle: 'Master switch for all app alerts',
                  value: _pushEnabled,
                  onChanged: (v) => setState(() => _pushEnabled = v),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('NOTIFY ME ABOUT', style: AppTextStyles.labelSm),
            const SizedBox(height: AppSpacing.xs),
            _SectionCard(
              children: [
                _ToggleTile(
                  icon: Icons.receipt_long_rounded,
                  title: 'Order Updates',
                  subtitle: 'Confirmations, packing, and readiness',
                  value: _orderUpdates,
                  onChanged: _pushEnabled ? (v) => setState(() => _orderUpdates = v) : null,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: Icons.local_shipping_rounded,
                  title: 'Delivery Updates',
                  subtitle: 'Rider dispatch and live ETA changes',
                  value: _deliveryUpdates,
                  onChanged: _pushEnabled ? (v) => setState(() => _deliveryUpdates = v) : null,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: Icons.stars_rounded,
                  title: 'Loyalty & Rewards',
                  subtitle: 'Points earned and reward reminders',
                  value: _loyaltyUpdates,
                  onChanged: _pushEnabled ? (v) => setState(() => _loyaltyUpdates = v) : null,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: Icons.local_offer_rounded,
                  title: 'Promos & Offers',
                  subtitle: 'Sales, discounts, and seasonal deals',
                  value: _promos,
                  onChanged: _pushEnabled ? (v) => setState(() => _promos = v) : null,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: Icons.build_circle_outlined,
                  title: 'System Announcements',
                  subtitle: 'Maintenance and app-wide notices',
                  value: _systemAnnouncements,
                  onChanged: _pushEnabled ? (v) => setState(() => _systemAnnouncements = v) : null,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('DELIVERY CHANNELS', style: AppTextStyles.labelSm),
            const SizedBox(height: AppSpacing.xs),
            _SectionCard(
              children: [
                _ToggleTile(
                  icon: Icons.email_outlined,
                  title: 'Email Notifications',
                  subtitle: 'Receipts and account emails',
                  value: _emailNotifications,
                  onChanged: (v) => setState(() => _emailNotifications = v),
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: Icons.sms_outlined,
                  title: 'SMS Notifications',
                  subtitle: 'Text alerts for critical updates',
                  value: _smsNotifications,
                  onChanged: (v) => setState(() => _smsNotifications = v),
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: PrimaryButton(
            label: 'Save Preferences',
            icon: Icons.check_rounded,
            loading: _saving,
            onPressed: (_saving || _loadingPrefs || _loadError != null) ? null : _save,
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;

  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(children: children),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: AppColors.darkBrown),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelLg),
                Text(subtitle, style: AppTextStyles.bodySm),
              ],
            ),
          ),
          Switch(value: value, activeThumbColor: AppColors.primary, onChanged: onChanged),
        ],
      ),
    );
  }
}
