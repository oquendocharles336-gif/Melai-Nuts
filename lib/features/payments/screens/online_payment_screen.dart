import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/order.dart';
import '../../../data/models/payment.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../customer/screens/order_confirmation_screen.dart';
import '../../customer/screens/order_tracking_screen.dart';

/// Waiting screen for an order paid through HitPay's hosted checkout.
///
/// The order already exists when this opens, so nothing here can lose it. The
/// payment status is read from the server (polled every 3 seconds and when the
/// app returns to the foreground); only HitPay's webhook can mark it paid.
class OnlinePaymentScreen extends StatefulWidget {
  final Order order;
  final int itemCount;

  /// Set when the checkout page could not be opened right after placing the
  /// order; the screen then starts with a "Pay now" retry.
  final String? startError;

  const OnlinePaymentScreen({
    super.key,
    required this.order,
    required this.itemCount,
    this.startError,
  });

  @override
  State<OnlinePaymentScreen> createState() => _OnlinePaymentScreenState();
}

class _OnlinePaymentScreenState extends State<OnlinePaymentScreen> with WidgetsBindingObserver {
  static const Duration _pollInterval = Duration(seconds: 3);

  Timer? _timer;
  PaymentTransaction? _txn;
  String? _message;
  bool _opening = false;
  bool _refreshing = false;
  late bool _pageOpened;

  PaymentStatus? get _status => _txn?.status;
  bool get _isSuccess => _status == PaymentStatus.success;
  bool get _isFailed => _status == PaymentStatus.failed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageOpened = widget.startError == null;
    _message = widget.startError;
    _txn = CustomerDataStore.instance.paymentForOrder(widget.order.id);
    _refresh();
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isSuccess) {
      _refresh();
      _startPolling();
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final fresh = await PaymentsRepository.instance.fetchForOrder(widget.order.id);
      if (!mounted) return;
      if (fresh != null) CustomerDataStore.instance.upsertPayment(fresh);
      setState(() => _txn = fresh ?? _txn);
      if (fresh != null && (fresh.status == PaymentStatus.success || fresh.status == PaymentStatus.failed)) {
        _stopPolling();
      }
    } catch (_) {
      // A missed poll is harmless; the next tick (or pull-to-refresh) retries.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _openPaymentPage() async {
    setState(() {
      _opening = true;
      _message = null;
    });
    try {
      final url = await PaymentsRepository.instance.startHitpayCheckout(widget.order.id);
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() {
        _pageOpened = opened;
        _message = opened ? null : 'We could not open the payment page. Please try again.';
      });
      if (opened) {
        _startPolling();
        unawaited(_refresh());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = AppErrors.from(e, scope: ErrorScope.order).message);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _viewOrder() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OrderTrackingScreen(order: widget.order)),
    );
  }

  void _continueToConfirmation() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => OrderConfirmationScreen(
          order: widget.order,
          itemCount: widget.itemCount,
          total: widget.order.total,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color accent;
    final Color accentBg;
    final IconData icon;
    final String title;
    final String body;
    if (_isSuccess) {
      accent = AppColors.success;
      accentBg = AppColors.successBg;
      icon = Icons.check_rounded;
      title = 'Payment received';
      body = 'Thank you! Your payment for order ${widget.order.id} is confirmed.';
    } else if (_isFailed) {
      accent = AppColors.error;
      accentBg = AppColors.error.withValues(alpha: 0.1);
      icon = Icons.error_outline_rounded;
      title = 'Payment failed';
      body = 'Your order is saved, but the payment did not go through. You can try again.';
    } else {
      accent = AppColors.warning;
      accentBg = AppColors.warningBg;
      icon = Icons.hourglass_top_rounded;
      title = _pageOpened ? 'Waiting for payment' : 'Payment not started';
      body = _pageOpened
          ? 'Finish paying on the HitPay page. This screen updates by itself once we receive your payment.'
          : 'Your order is saved. Tap Pay now to open the payment page.';
    }

    final retryLabel = _isFailed ? 'Try payment again' : (_pageOpened ? 'Open payment page again' : 'Pay now');

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Online Payment', showBack: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(color: accentBg, shape: BoxShape.circle),
                  child: Icon(icon, color: accent, size: 44),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTextStyles.headlineSm.copyWith(color: accent),
              ),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
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
                  children: [
                    _InfoLine('Order', widget.order.id),
                    _InfoLine('Amount', '₱${widget.order.total.toStringAsFixed(2)}'),
                    _InfoLine('Status', _status?.label ?? 'Pending', valueColor: accent),
                  ],
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (_isSuccess) ...[
                PrimaryButton(
                  label: 'Continue',
                  icon: Icons.arrow_forward_rounded,
                  onPressed: _continueToConfirmation,
                ),
                const SizedBox(height: 10),
                SecondaryButton(label: 'View order', onPressed: _viewOrder),
              ] else ...[
                PrimaryButton(
                  label: retryLabel,
                  icon: Icons.open_in_new_rounded,
                  loading: _opening,
                  onPressed: _openPaymentPage,
                ),
                const SizedBox(height: 10),
                SecondaryButton(label: 'View order', onPressed: _viewOrder),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoLine(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodyMd),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: AppTextStyles.labelLg.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
