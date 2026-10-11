import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/notification_item.dart';
import '../../../core/services/pending_writes_service.dart';
import '../../../core/services/customer_data_store.dart';

class NotificationDetailScreen extends StatefulWidget {
  final NotificationItem item;

  const NotificationDetailScreen({super.key, required this.item});

  @override
  State<NotificationDetailScreen> createState() => _NotificationDetailScreenState();
}

class _NotificationDetailScreenState extends State<NotificationDetailScreen> {
  bool _deleting = false;

  NotificationItem get item => widget.item;

  /// Removes the notification from the list right away and deletes it on the
  /// server. If the server can't be reached the delete is kept on this device
  /// and retried (and the customer is told it isn't done on their account
  /// yet); if the server refuses it, the notification comes back.
  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await CustomerDataStore.instance.deleteNotification(item.id);
      navigator.pop();
      if (outcome == null) return;
      if (outcome.kind == WriteOutcomeKind.queued) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Deleted on this device — it will be removed from your account when the server is reachable.'),
          ));
      } else if (outcome.kind == WriteOutcomeKind.rejected) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Could not delete: ${outcome.message ?? 'the server refused it'}'),
          ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(AppErrors.from(e).message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Notification', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
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
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: item.category.color.withValues(alpha: 0.12), shape: BoxShape.circle),
                        child: Icon(item.category.icon, color: item.category.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.category.label, style: AppTextStyles.labelSm.copyWith(color: item.category.color)),
                            Text(item.title, style: AppTextStyles.headlineSm),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  Text(item.body, style: AppTextStyles.bodyMd),
                  const SizedBox(height: 14),
                  Text(_formatDate(item.time), style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SecondaryButton(
              label: _deleting ? 'Deleting...' : 'Delete Notification',
              icon: Icons.delete_outline_rounded,
              onPressed: _deleting ? null : _delete,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} at $hour:$minute $ampm';
  }
}
