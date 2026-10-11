import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/order.dart';
import '../../../data/models/refund_summary.dart';
import '../../../data/repositories/refunds_repository.dart';

/// What was refunded on one of the customer's orders, as the database
/// computed it (`get_my_order_refunds`): the refunded amount (a partial refund
/// says so), a refund still pending, and the loyalty points reversed.
///
/// Renders nothing for orders that never had a refund request. When the
/// figures cannot be loaded it says so ("—"), it never shows 0.
class OrderRefundInfo extends StatefulWidget {
  final String orderId;
  final OrderStatus status;

  const OrderRefundInfo({super.key, required this.orderId, required this.status});

  /// Only orders in a refund state ask the server.
  static bool appliesTo(OrderStatus s) => s == OrderStatus.refundRequested || s == OrderStatus.refunded;

  @override
  State<OrderRefundInfo> createState() => _OrderRefundInfoState();
}

class _OrderRefundInfoState extends State<OrderRefundInfo> {
  Future<OrderRefundSummary?>? _future;

  @override
  void initState() {
    super.initState();
    if (OrderRefundInfo.appliesTo(widget.status)) {
      _future = RefundsRepository.instance.orderRefund(widget.orderId);
    }
  }

  @override
  void didUpdateWidget(covariant OrderRefundInfo old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status || old.orderId != widget.orderId) {
      _future = OrderRefundInfo.appliesTo(widget.status)
          ? RefundsRepository.instance.orderRefund(widget.orderId, fresh: true)
          : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<OrderRefundSummary?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
        if (snap.hasError) {
          return Text('Refund amount: — (could not load right now)', style: AppTextStyles.bodySm);
        }
        final r = snap.data;
        if (r == null || r.state == 'none') return const SizedBox.shrink();
        final lines = <Widget>[
          if (r.isRefunded)
            Text(
              '${r.isPartial ? 'Partially refunded' : 'Refunded'}: ${peso(r.refundedAmount)}'
              '${r.refundedUnits > 0 ? ' (${r.refundedUnits} item${r.refundedUnits == 1 ? '' : 's'})' : ''}',
              style: AppTextStyles.labelMd.copyWith(color: AppColors.error),
            ),
          if (r.hasPending)
            Text('Refund of ${peso(r.pendingAmount)} is being reviewed', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          if (r.pointsReversed > 0)
            Text('${r.pointsReversed} loyalty point${r.pointsReversed == 1 ? '' : 's'} reversed', style: AppTextStyles.bodySm),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: lines);
      },
    );
  }
}
