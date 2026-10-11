import 'package:flutter/material.dart';

import '../../../core/services/permission_service.dart';
import '../../../core/services/push_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Settings > Permissions: the status of each device permission the app uses
/// and a button to allow it or manage it in the phone's Settings.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  final Map<AppPermission, PermissionStatusView> _status = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the phone's Settings: show the new status.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final next = <AppPermission, PermissionStatusView>{};
    for (final p in AppPermission.values) {
      next[p] = await PermissionService.instance.status(p);
    }
    if (!mounted) return;
    setState(() {
      _status
        ..clear()
        ..addAll(next);
      _loading = false;
    });
  }

  Future<void> _act(AppPermission p) async {
    final service = PermissionService.instance;
    final s = _status[p];
    if (s == PermissionStatusView.blocked || s == PermissionStatusView.allowed || s == PermissionStatusView.denied) {
      await service.openAppSettings();
    } else if (p == AppPermission.location) {
      await service.requestLocation(context, PermissionPurpose.pinAddress);
    } else if (p == AppPermission.notifications) {
      final outcome = await service.requestNotifications(context, force: true);
      if (outcome == PermissionOutcome.granted) await PushService.instance.registerIfAllowed();
    } else {
      await service.openAppSettings();
    }
    await _load();
  }

  String _statusText(AppLocalizations t, PermissionStatusView s) => switch (s) {
        PermissionStatusView.allowed => t.permStatusAllowed,
        PermissionStatusView.denied => t.permStatusDenied,
        PermissionStatusView.blocked => t.permStatusBlocked,
        PermissionStatusView.notAsked => t.permStatusNotAsked,
        PermissionStatusView.onUse => t.permStatusOnUse,
        PermissionStatusView.unsupported => t.permStatusUnsupported,
      };

  Color _statusColor(PermissionStatusView s) => switch (s) {
        PermissionStatusView.allowed => AppColors.success,
        PermissionStatusView.denied || PermissionStatusView.blocked => AppColors.error,
        _ => AppColors.textSecondary,
      };

  String _use(AppLocalizations t, AppPermission p) => switch (p) {
        AppPermission.camera => t.permCameraUse,
        AppPermission.location => t.permLocationUse,
        AppPermission.notifications => t.permNotificationsUse,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: t.permissionsTitle, showBack: true),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Text(t.permissionsIntro, style: AppTextStyles.bodyMd),
                    const SizedBox(height: AppSpacing.md),
                    for (final p in AppPermission.values) _tile(t, p),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _tile(AppLocalizations t, AppPermission p) {
    final s = _status[p] ?? PermissionStatusView.unsupported;
    final actionable = s != PermissionStatusView.unsupported;
    final allow = s == PermissionStatusView.notAsked;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(PermissionTexts.icon(p), color: AppColors.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(PermissionTexts.title(t, p), style: AppTextStyles.titleMd),
                  const SizedBox(height: AppSpacing.xs2),
                  Text(_use(t, p), style: AppTextStyles.bodySm),
                  const SizedBox(height: AppSpacing.xs2),
                  Text(_statusText(t, s),
                      style: AppTextStyles.labelMd.copyWith(color: _statusColor(s))),
                ],
              ),
            ),
            if (actionable)
              TextButton(
                onPressed: () => _act(p),
                child: Text(allow ? t.permAllow : t.permManage),
              ),
          ],
        ),
      ),
    );
  }
}
