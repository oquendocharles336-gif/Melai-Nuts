import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/app_logo.dart';
import '../../../core/widgets/pending_sync_chip.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/staff_models.dart';

/// Opens the e-receipt of [order] in a sheet, rendered from the copy stored
/// on this device (SQLite, `staff_order_receipts`) so it works with no
/// connection. Falls back to [order] itself only if no copy was stored yet.
Future<void> showEReceipt(BuildContext context, StaffOrder order) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.canvas,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) => _EReceiptSheet(order: order, controller: controller),
    ),
  );
}

class _EReceiptSheet extends StatefulWidget {
  final StaffOrder order;
  final ScrollController controller;

  const _EReceiptSheet({required this.order, required this.controller});

  @override
  State<_EReceiptSheet> createState() => _EReceiptSheetState();
}

class _EReceiptSheetState extends State<_EReceiptSheet> {
  late Future<StaffOrder?> _load = StaffStore.instance.storedReceipt(widget.order.id);

  void _retry() => setState(() => _load = StaffStore.instance.storedReceipt(widget.order.id));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StaffOrder?>(
      future: _load,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const StateLoadingView(message: 'Loading receipt…');
        }
        if (snap.hasError) {
          return StateErrorView(error: snap.error, onRetry: _retry);
        }
        final order = snap.data ?? widget.order;
        return ListView(
          controller: widget.controller,
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
          children: [EReceiptView(order: order)],
        );
      },
    );
  }
}

/// A Melai Nuts e-receipt: order number, date, branch, cashier, every item
/// with quantity and price, totals and payment. A sale rung up offline shows
/// "Pending sync" (or "Sync failed") until the server has accepted it.
class EReceiptView extends StatelessWidget {
  final StaffOrder order;

  const EReceiptView({super.key, required this.order});

  static final DateFormat _date = DateFormat('MMM d, y • h:mm a');

  @override
  Widget build(BuildContext context) {
    final o = order;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: AppLogo(size: 48)),
          const SizedBox(height: 6),
          Text('Melai Nuts', textAlign: TextAlign.center, style: AppTextStyles.titleMd.copyWith(color: AppColors.primary)),
          if (o.branchName.isNotEmpty)
            Text(o.branchName, textAlign: TextAlign.center, style: AppTextStyles.bodySm),
          const SizedBox(height: 4),
          Text('E-RECEIPT', textAlign: TextAlign.center, style: AppTextStyles.labelSm.copyWith(letterSpacing: 1.2)),
          if (o.pendingSync || o.syncError != null) ...[
            const SizedBox(height: 8),
            Center(child: PendingSyncChip(failed: o.syncError != null)),
            const SizedBox(height: 4),
            Text(
              o.syncError ??
                  'Recorded on this device while offline. The order number and totals are confirmed by the server when it syncs.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm.copyWith(color: o.syncError != null ? AppColors.error : null),
            ),
          ],
          const Divider(height: 24),
          _row('Order No.', o.id, bold: true),
          _row('Date', _date.format(o.createdAt)),
          _row('Channel', o.channelLabel),
          _row('Customer', o.customerLabel),
          if ((o.cashierName ?? '').isNotEmpty) _row('Cashier', o.cashierName!),
          const Divider(height: 24),
          if (o.items.isEmpty)
            Text('No items on this receipt.', style: AppTextStyles.bodySm)
          else
            for (final i in o.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i.productName}${i.variantLabel.isEmpty ? '' : ' • ${i.variantLabel}'}',
                            style: AppTextStyles.bodyMd,
                          ),
                          Text('${i.quantity} × ${peso(i.unitPrice)}', style: AppTextStyles.bodySm),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(peso(i.total), style: AppTextStyles.bodyMd),
                  ],
                ),
              ),
          const Divider(height: 24),
          _row('Subtotal', peso(o.subtotal)),
          if (o.discount > 0) _row('Discount', '-${peso(o.discount)}'),
          if (o.deliveryFee > 0) _row('Delivery fee', peso(o.deliveryFee)),
          _row('Total', peso(o.total), bold: true),
          const Divider(height: 24),
          _row('Payment method', _method(o.paymentMethod)),
          if (o.downpaymentAmount != null) _row('Paid online', peso(o.downpaymentAmount!)),
          if ((o.payment?.referenceNumber ?? '').isNotEmpty && o.payment!.method != 'cash')
            _row('Reference', o.payment!.referenceNumber),
          if (o.cashReceived != null) _row('Cash received', peso(o.cashReceived!)),
          if (o.changeGiven != null) _row('Change', peso(o.changeGiven!)),
          if (o.pointsEarned > 0) _row('Loyalty points earned', '+${o.pointsEarned}'),
          if (o.refund != null && o.refund!.isRefunded) _row('Refunded', '-${peso(o.refund!.refundedAmount)}'),
          const SizedBox(height: 12),
          Text('Thank you for choosing Melai Nuts!', textAlign: TextAlign.center, style: AppTextStyles.bodySm),
        ],
      ),
    );
  }

  static String _method(String m) => switch (m) {
        'cash' => 'Cash',
        'gcash' => 'GCash',
        'maya' => 'Maya',
        'card' => 'Card',
        '' => '—',
        _ => m,
      };

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd,
              ),
            ),
          ],
        ),
      );
}
