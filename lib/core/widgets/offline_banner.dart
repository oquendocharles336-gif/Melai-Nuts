import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../data/repositories/products_repository.dart';
import '../../features/customer/cart_controller.dart';
import '../services/auth_service.dart';
import '../services/branch_controller.dart';
import '../services/checkout_attempt_store.dart';
import '../services/connectivity_service.dart';
import '../services/customer_data_store.dart';
import '../services/offline_read_cache_client.dart';
import '../services/pending_writes_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Honest connectivity / sync strip for customer screens. Each strip
/// reports a DIFFERENT, real state — never a guess from one slow request:
///
///  * offline           — no network path (from `ConnectivityService`).
///  * saved data        — online, but the server couldn't answer, so what's
///                        on screen is the last saved copy (`CacheStatus`).
///  * waiting to sync   — changes stored on this device, not yet accepted by
///                        the server (`PendingWritesService`, unsynced cart).
///  * failed to sync    — the server refused a queued change; the customer
///                        chooses Retry or Discard (never silently dropped).
///  * order confirmed   — an earlier, unconfirmed checkout was found on the
///                        server after reconnecting (`CheckoutAttemptStore`).
///
/// Wrap any customer screen's body in this (see `CustomerPortalScreen`).
class OfflineBanner extends StatelessWidget {
  final Widget child;
  const OfflineBanner({super.key, required this.child});

  static String _when(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    return DateFormat('MMM d, h:mm a').format(t);
  }

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  Future<void> _refreshAll() async {
    await Future.wait([
      ProductsRepository.instance.loadCatalog(branchId: BranchController.instance.selectedBranch?.id),
      CustomerDataStore.instance.refresh(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        ConnectivityService.instance,
        CacheStatus.instance,
        PendingWritesService.instance,
        CartController.instance,
        CheckoutAttemptStore.instance,
      ]),
      builder: (context, _) {
        final uid = AuthService.instance.currentFirebaseUser?.uid;
        final online = ConnectivityService.instance.isOnline;
        final cache = CacheStatus.instance;
        final writes = PendingWritesService.instance;
        final pending = uid == null ? 0 : writes.pendingCount(uid);
        final failed = uid == null ? 0 : writes.failedCount(uid);
        final cartUnsynced = uid != null && CartController.instance.hasUnsyncedChanges;
        final recovered = uid == null ? null : CheckoutAttemptStore.instance.recoveredOrder;

        final strips = <_Strip>[];
        final savedAt = cache.oldestSavedAt;
        if (!online) {
          strips.add(_Strip(
            icon: Icons.cloud_off_rounded,
            color: AppColors.textMuted,
            text: 'You\'re offline — showing saved data'
                '${savedAt != null ? ' from ${_when(savedAt)}' : ''}. '
                'Orders, payments and refunds can\'t be placed until you reconnect.',
          ));
        } else if (cache.isShowingSavedData) {
          strips.add(_Strip(
            icon: Icons.history_rounded,
            color: AppColors.textMuted,
            text: 'Can\'t reach the server right now — showing data saved '
                '${savedAt != null ? _when(savedAt) : 'earlier'}.',
            actionLabel: 'Retry',
            onAction: _refreshAll,
          ));
        }
        if (pending > 0) {
          strips.add(_Strip(
            icon: Icons.sync_rounded,
            color: AppColors.warning,
            text: '${_plural(pending, 'change')} saved on this device, waiting to sync. '
                'Not saved to your account yet.',
          ));
        }
        if (cartUnsynced) {
          strips.add(const _Strip(
            icon: Icons.shopping_cart_outlined,
            color: AppColors.warning,
            text: 'Your cart changes haven\'t synced to your account yet.',
          ));
        }
        if (failed > 0 && uid != null) {
          final owner = uid;
          strips.add(_Strip(
            icon: Icons.error_outline_rounded,
            color: AppColors.error,
            text: '${_plural(failed, 'change')} couldn\'t be saved: '
                '${writes.firstFailureMessage(owner) ?? 'the server refused it'}.',
            actionLabel: 'Retry',
            onAction: () => writes.retryFailed(owner),
            secondaryLabel: 'Discard',
            onSecondary: () async {
              await writes.discardFailed(owner);
              await CustomerDataStore.instance.refresh();
            },
          ));
        }
        if (recovered != null) {
          strips.add(_Strip(
            icon: Icons.check_circle_outline_rounded,
            color: AppColors.success,
            text: 'Your earlier order (₱${recovered.total.toStringAsFixed(0)}) was confirmed by the '
                'server after you reconnected. Find it in My Orders.',
            actionLabel: 'Dismiss',
            onAction: () async => CheckoutAttemptStore.instance.dismissRecovered(),
          ));
        }

        return Column(
          children: [
            for (var i = 0; i < strips.length; i++) strips[i].build(useSafeArea: i == 0),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

class _Strip {
  final IconData icon;
  final Color color;
  final String text;
  final String? actionLabel;
  final Future<void> Function()? onAction;
  final String? secondaryLabel;
  final Future<void> Function()? onSecondary;

  const _Strip({
    required this.icon,
    required this.color,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  Widget build({required bool useSafeArea}) {
    final row = Row(
      children: [
        Icon(icon, size: 14, color: Colors.white),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: AppTextStyles.labelSm.copyWith(color: Colors.white)),
        ),
        if (actionLabel != null)
          _StripButton(label: actionLabel!, onTap: onAction),
        if (secondaryLabel != null)
          _StripButton(label: secondaryLabel!, onTap: onSecondary),
      ],
    );
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: useSafeArea ? SafeArea(bottom: false, child: row) : row,
    );
  }
}

class _StripButton extends StatelessWidget {
  final String label;
  final Future<void> Function()? onTap;
  const _StripButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap == null ? null : () => onTap!(),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: AppTextStyles.labelMd.copyWith(color: Colors.white, decoration: TextDecoration.underline)),
    );
  }
}
