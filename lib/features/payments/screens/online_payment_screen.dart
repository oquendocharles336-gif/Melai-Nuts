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
import '../../../data/models/cod_downpayment.dart';
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

  /// Opened from the order details to pay an order placed earlier: the screen
  /// starts with "Pay now" instead of assuming the payment page is open.
  final bool resume;

  const OnlinePaymentScreen({
    super.key,
    required this.order,
    required this.itemCount,
    this.startError,
    this.resume = false,
  });

  @override
  State<OnlinePaymentScreen> createState() => _OnlinePaymentScreenState();
}

class _OnlinePaymentScreenState extends State<OnlinePaymentScreen> with WidgetsBindingObserver {
  static const Duration _pollInterval = Duration(seconds: 3);

  Timer? _timer;
  PaymentTransaction? _txn;

  /// Set for a pickup order: this screen then pays only its downpayment.
  OrderDownpayment? _downpayment;
  String? _message;
  bool _opening = false;
  bool _refreshing = false;
  late bool _pageOpened;

  bool get _paysDownpayment => widget.order.downpayment != null;
  bool get _isExpired => _downpayment?.isExpired ?? false;

  PaymentStatus? get _status {
    if (_paysDownpayment) {
      if (_downpayment?.isPaid ?? false) return PaymentStatus.success;
      if (_downpayment?.status == 'failed') return PaymentStatus.failed;
      if (_downpayment?.status == 'processing') return PaymentStatus.processing;
      return PaymentStatus.pending;
    }
    return _txn?.status;
  }

  bool get _isSuccess => _status == PaymentStatus.success;
  bool get _isFailed => _status == PaymentStatus.failed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageOpened = widget.startError == null && !widget.resume;
    _message = widget.startError;
    _downpayment = widget.order.downpayment;
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
      if (_paysDownpayment) {
        final fresh = await PaymentsRepository.instance.fetchDownpayment(widget.order.id);
        if (!mounted) return;
        setState(() => _downpayment = fresh ?? _downpayment);
        if (fresh != null && !(fresh.status == 'pending' || fresh.status == 'processing')) _stopPolling();
        return;
      }
      final fresh = await PaymentsRepository.instance.fetchForOrder(widget.order.id);
      if (!mounted) return;
      if (fresh != null) CustomerDataStore.instance.upsertPayment(fresh);
      setState(() => _txn = fresh ?? _txn);
      if (fresh != null && (fresh.status == PaymentStatus.success || fresh.status == PaymentStatus.failed)) {
        _stopPolling();
      }
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'online_payment_screen:104');
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
    // Paying an earlier order: go back to its details.
    if (widget.resume) {
      Navigator.of(context).pop();
      return;
    }
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
    if (_isExpired) {
      accent = AppColors.error;
      accentBg = AppColors.error.withValues(alpha: 0.1);
      icon = Icons.timer_off_rounded;
      title = 'Time to pay has ended';
      body = 'Order ${widget.order.id} was cancelled because its downpayment was not paid in time. '
          'Nothing was charged. If you did pay, we will refund it.';
    } else if (_isSuccess) {
      accent = AppColors.success;
      accentBg = AppColors.successBg;
      icon = Icons.check_rounded;
      title = _paysDownpayment ? 'Downpayment received' : 'Payment received';
      body = _paysDownpayment
          ? 'Thank you! We are preparing order ${widget.order.id}. '
              'Please bring ${_money(widget.order.cashBalance)} in cash when you pick it up.'
          : 'Thank you! Your payment for order ${widget.order.id} is confirmed.';
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
                    if (_paysDownpayment) ...[
                      _InfoLine('Downpayment', _money(_downpayment?.amount ?? widget.order.downpayment!.amount)),
                      _InfoLine('Cash at pickup', _money(widget.order.cashBalance)),
                    ] else
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
              if (_isExpired) ...[
                SecondaryButton(label: 'View order', onPressed: _viewOrder),
              ] else if (_isSuccess) ...[
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

String _money(double amount) => '₱${amount.toStringAsFixed(2)}';

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
