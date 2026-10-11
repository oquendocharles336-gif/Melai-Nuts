import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/payment.dart';
import '../../../data/repositories/payments_repository.dart';
import 'payment_status_screen.dart';
import '../../../core/services/customer_data_store.dart';

/// Shows how to pay for an already-placed order.
///
/// The payment record is created by the database when the order is placed
/// (always `pending`), using the method chosen at checkout. This screen
/// therefore never writes a payment and never asks for card details:
///
///  * Collecting a card number in the app without a PCI-compliant gateway SDK
///    would put raw card data on the device and in our logs/crash reports.
///  * A "Pay Now" button that only stored a `pending` row would look like a
///    charge that never happened.
///
/// Online payment (GCash/Maya/card) needs a real payment provider whose secret
/// key lives on a server (Edge Function) and whose webhook confirms the
/// payment. Until that exists, this screen tells the customer exactly what is
/// true: pay the branch/rider, and the status updates when the branch confirms.
class PaymentScreen extends StatefulWidget {
  final String orderId;
  final double amount;
  final PaymentMethod initialMethod;

  const PaymentScreen({
    super.key,
    required this.orderId,
    required this.amount,
    this.initialMethod = PaymentMethod.gcash,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  PaymentTransaction? _txn;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _txn = CustomerDataStore.instance.paymentForOrder(widget.orderId);
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final fresh = await PaymentsRepository.instance.fetchForOrder(widget.orderId);
      if (!mounted) return;
      setState(() => _txn = fresh ?? _txn);
    } catch (e) {
      // Keep whatever we already know, and say the latest details could not
      // be loaded, with a retry.
      if (mounted) setState(() => _error = AppErrors.from(e).message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  PaymentMethod get _method => _txn?.method ?? widget.initialMethod;
  double get _amount => _txn?.amount ?? widget.amount;

  String get _instructions {
    if (_method == PaymentMethod.cash) {
      return 'Pay the exact amount at the branch counter or to the rider upon arrival.';
    }
    return 'In-app ${_method.label} payment is not available yet. Please pay the branch or '
        'the rider directly. Your payment status updates here once the branch confirms it.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Pay for Order', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Column(
                children: [
                  Text('Amount Due', style: AppTextStyles.labelMd),
                  const SizedBox(height: 4),
                  Text(
                    '₱${_amount.toStringAsFixed(0)}',
                    style: AppTextStyles.headlineLg.copyWith(color: AppColors.primaryDark),
                  ),
                  const SizedBox(height: 4),
                  Text('Order ${widget.orderId}', style: AppTextStyles.bodySm),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Payment Method', style: AppTextStyles.titleMd),
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary, width: 1.6),
              ),
              child: Row(
                children: [
                  Icon(_method.icon, color: AppColors.darkBrown),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_method.label, style: AppTextStyles.labelLg),
                        Text('Chosen at checkout', style: AppTextStyles.bodySm),
                      ],
                    ),
                  ),
                  if (_loading)
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.warningBg,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, color: AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_instructions, style: AppTextStyles.bodySm)),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Could not load the latest payment details. $_error',
                      style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading ? null : _load,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: PrimaryButton(
            label: 'Check Payment Status',
            icon: Icons.receipt_long_rounded,
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => PaymentStatusScreen(orderId: widget.orderId, amount: _amount),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
