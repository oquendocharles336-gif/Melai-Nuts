import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'order.dart';

enum RefundStatus { pending, approved, processing, completed, rejected }

extension RefundStatusX on RefundStatus {
  String get label {
    switch (this) {
      case RefundStatus.pending:
        return 'Pending Review';
      case RefundStatus.approved:
        return 'Approved';
      case RefundStatus.processing:
        return 'Processing';
      case RefundStatus.completed:
        return 'Refunded';
      case RefundStatus.rejected:
        return 'Rejected';
    }
  }

  Color get color {
    switch (this) {
      case RefundStatus.pending:
        return AppColors.warning;
      case RefundStatus.approved:
      case RefundStatus.processing:
        return AppColors.primary;
      case RefundStatus.completed:
        return AppColors.success;
      case RefundStatus.rejected:
        return AppColors.error;
    }
  }

  bool get isFinal => this == RefundStatus.completed || this == RefundStatus.rejected;
}

const List<String> kRefundReasons = [
  'Damaged / Spoiled Product',
  'Wrong Item Delivered',
  'Missing Item(s)',
  'Order Arrived Too Late',
  'Changed My Mind',
  'Other',
];

class RefundRequest {
  final String id;
  final String orderId;
  final DateTime requestedDate;
  final RefundStatus status;
  final String reason;
  final String notes;
  final List<OrderItem> items;
  final double amount;
  final String paymentMethod;
  final List<OrderTimelineStep> timeline;

  const RefundRequest({
    required this.id,
    required this.orderId,
    required this.requestedDate,
    required this.status,
    required this.reason,
    this.notes = '',
    required this.items,
    required this.amount,
    required this.paymentMethod,
    this.timeline = const [],
  });

  int get itemCount => items.fold(0, (sum, i) => sum + i.quantity);

  factory RefundRequest.fromRow(
    Map<String, dynamic> row, {
    required List<Map<String, dynamic>> itemRows,
    List<Map<String, dynamic>> eventRows = const [],
  }) {
    return RefundRequest(
      id: row['id'] as String,
      orderId: row['order_id'] as String,
      requestedDate: DateTime.parse(row['created_at'] as String).toLocal(),
      status: RefundStatus.values.byName(row['status'] as String),
      reason: row['reason'] as String,
      notes: (row['notes'] as String?) ?? '',
      items: itemRows.map(OrderItem.fromRow).toList(),
      amount: (row['amount'] as num).toDouble(),
      paymentMethod: row['payment_method'] as String,
      timeline: _timelineFromEvents(eventRows),
    );
  }

  static List<OrderTimelineStep> _timelineFromEvents(List<Map<String, dynamic>> rows) {
    final steps = <OrderTimelineStep>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final status = RefundStatus.values.byName(row['status'] as String);
      final isLast = i == rows.length - 1;
      final createdAt = DateTime.parse(row['created_at'] as String).toLocal();
      steps.add(
        OrderTimelineStep(
          label: status.label,
          description: (row['note'] as String?) ?? status.label,
          time: '${createdAt.month}/${createdAt.day} ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}',
          done: true,
          current: isLast,
        ),
      );
    }
    return steps;
  }
}
