import 'package:flutter/material.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/utils/app_error.dart';
import '../../../data/models/loyalty.dart';
import '../../../data/repositories/loyalty_repository.dart';

bool _redeeming = false;

/// Redeems [reward] for real (atomic check-and-deduct via the
/// `redeem_reward` Supabase function), refreshes the cached balance/history,
/// and navigates to [RedemptionSuccessScreen] with the real new balance —
/// or shows an error (e.g. not enough points) if it fails. No points ever
/// move locally before the server confirms it.
///
/// Shows a blocking progress dialog while the request is running (loading
/// state) and ignores extra taps until it finishes, so one tap can never
/// redeem twice.
Future<void> redeemRewardAndNavigate(BuildContext context, RewardItem reward) async {
  if (_redeeming) return;
  // Spending points needs the server's answer right now; it is never queued
  // and never shown as done while offline.
  if (!ConnectivityService.instance.isOnline) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You\'re offline. Reconnect to redeem — no points have been used.')),
    );
    return;
  }
  _redeeming = true;

  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );

  int? newBalance;
  Object? failure;
  try {
    newBalance = await AppErrors.guard(
      () => LoyaltyRepository.instance.redeemReward(reward.id),
      timeout: AppErrors.rpcTimeout,
    );
  } catch (e) {
    failure = e;
  }

  // Close the progress dialog.
  if (navigator.mounted) navigator.pop();

  if (failure != null) {
    _redeeming = false;
    final error = AppErrors.from(failure);
    if (error.isConnectivity) {
      // Unknown outcome: re-read the real balance instead of guessing.
      await CustomerDataStore.instance.refresh();
    }
    if (!context.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(error.isConnectivity
            ? 'Could not reach the server, so we can\'t confirm this redemption. Check your points history before trying again.'
            : 'Could not redeem: ${error.message}'),
        duration: const Duration(seconds: 5),
      ));
    return;
  }

  // The redemption itself succeeded; refresh the cached balance/history.
  // A failed refresh is reported through CustomerDataStore.error and does not
  // undo (or hide) the successful redemption.
  await CustomerDataStore.instance.refresh();
  _redeeming = false;
  if (!context.mounted) return;
  Navigator.pushNamed(
    context,
    '/customer/loyalty/redemption-success',
    arguments: RedemptionResult(reward: reward, pointsAfter: newBalance!),
  );
}
