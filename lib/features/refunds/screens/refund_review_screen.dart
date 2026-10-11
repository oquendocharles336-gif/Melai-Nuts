import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/order.dart';
import '../../../data/repositories/refunds_repository.dart';
import 'refund_confirmation_screen.dart';

class RefundReviewScreen extends StatefulWidget {
  final Order order;
  final List<OrderItem> items;
  final String reason;
  final String notes;
  final double amount;

  const RefundReviewScreen({
    super.key,
    required this.order,
    required this.items,
    required this.reason,
    required this.notes,
    required this.amount,
  });

  @override
  State<RefundReviewScreen> createState() => _RefundReviewScreenState();
}

class _RefundReviewScreenState extends State<RefundReviewScreen> {
  bool _agreed = false;
  bool _submitting = false;

  Future<void> _submit() async {
    // A refund request must reach the server; it is never queued or shown
    // as submitted while offline.
    if (!ConnectivityService.instance.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You\'re offline. Reconnect to submit your refund request — nothing has been submitted yet.')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      // Only the order, the chosen lines and the reason are sent. The server
      // decides eligibility, the refund amount and the initial status.
      final request = await RefundsRepository.instance.submitRequest(
        orderId: widget.order.id,
        reason: widget.reason,
        notes: widget.notes,
        items: widget.items,
      );
      // Only the server-created request (returned above) is shown.
      CustomerDataStore.instance.addRefund(request);
      unawaited(CustomerDataStore.instance.refresh());

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => RefundConfirmationScreen(request: request)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      if (AppErrors.from(e, scope: ErrorScope.refund).isConnectivity) {
        // Refund requests are not idempotent: the request may have reached
        // the server, so say so rather than inviting a blind resubmit.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('We couldn\'t confirm your refund request because the connection dropped. Check Refund History before submitting again to avoid a duplicate.'),
            duration: Duration(seconds: 6),
          ),
        );
      } else {
        AppErrors.showSnack(context, e, scope: ErrorScope.refund);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Review Refund Request', showBack: true),
      body: SafeArea(
        child: ListView(
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
                  Text('Order ${widget.order.id}', style: AppTextStyles.titleMd),
                  const Divider(height: 20),
                  for (final item in widget.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text('${item.quantity}x ${item.productName}', style: AppTextStyles.bodyMd)),
                          Text('₱${item.total.toStringAsFixed(0)}', style: AppTextStyles.bodyMd),
                        ],
                      ),
                    ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Estimated Refund', style: AppTextStyles.headlineSm),
                      Text(
                        '₱${widget.amount.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reason', style: AppTextStyles.bodySm),
                  Text(widget.reason, style: AppTextStyles.labelLg),
                  if (widget.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('Notes', style: AppTextStyles.bodySm),
                    Text(widget.notes, style: AppTextStyles.bodyMd),
                  ],
                  const SizedBox(height: 10),
                  Text('Refund Method', style: AppTextStyles.bodySm),
                  Text(widget.order.paymentMethod, style: AppTextStyles.labelLg),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'I confirm the details above are accurate and agree to Melai Nuts\' refund policy.',
                style: AppTextStyles.bodySm,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: PrimaryButton(
            label: 'Submit Refund Request',
            icon: Icons.send_rounded,
            loading: _submitting,
            onPressed: _agreed ? _submit : null,
          ),
        ),
      ),
    );
  }
}
