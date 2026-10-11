import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/payment.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../../core/services/customer_data_store.dart';

class PaymentStatusScreen extends StatefulWidget {
  final String orderId;
  final double amount;

  const PaymentStatusScreen({super.key, required this.orderId, this.amount = 0});

  @override
  State<PaymentStatusScreen> createState() => _PaymentStatusScreenState();
}

class _PaymentStatusScreenState extends State<PaymentStatusScreen> {
  PaymentTransaction? _txn;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _txn = CustomerDataStore.instance.paymentForOrder(widget.orderId); // last known, shown while refreshing
    _refresh();
  }

  /// Always reads the real status from the server; the payment can only be
  /// changed there (by the branch or a payment gateway), never by this app.
  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await PaymentsRepository.instance.fetchForOrder(widget.orderId);
      if (!mounted) return;
      if (fresh != null) CustomerDataStore.instance.upsertPayment(fresh);
      setState(() => _txn = fresh ?? _txn);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = AppErrors.from(e).message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final txn = _txn;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Payment Status', showBack: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text('Order ${widget.orderId}',
                              style: AppTextStyles.titleMd, overflow: TextOverflow.ellipsis),
                        ),
                        if (txn != null) ...[const SizedBox(width: 8), _StatusBadge(status: txn.status)],
                      ],
                    ),
                    const Divider(height: 24),
                    if (txn != null) ...[
                      _Row('Transaction ID', txn.id),
                      _Row('Method', txn.method.label),
                      _Row('Reference No.', txn.referenceNumber),
                      _Row('Amount', '₱${txn.amount.toStringAsFixed(0)}'),
                    ] else if (_loading)
                      const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                    else if (_error != null)
                      // Failed to load and nothing cached: say so (with a
                      // retry) rather than claiming there is no payment.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'We couldn\'t load this payment right now.',
                            style: AppTextStyles.bodyMd,
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _refresh,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Try Again'),
                          ),
                        ],
                      )
                    else
                      Text('No payment record found for this order.', style: AppTextStyles.bodyMd),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(_error!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
              ],
              if (txn != null &&
                  (txn.status == PaymentStatus.pending || txn.status == PaymentStatus.processing)) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Your payment is awaiting confirmation by the branch. This screen updates '
                  'once it has been confirmed.',
                  style: AppTextStyles.bodySm,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Refresh Status',
                icon: Icons.refresh_rounded,
                loading: _loading,
                onPressed: _loading ? null : _refresh,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final PaymentStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(status.label, style: AppTextStyles.labelMd.copyWith(color: status.color)),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodySm),
          Expanded(child: Text(value, style: AppTextStyles.labelLg, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}