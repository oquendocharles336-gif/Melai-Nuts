import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Lifecycle status of a customer order.
enum OrderStatus {
  pending,
  confirmed,
  preparing,
  readyForPickup,
  outForDelivery,
  completed,
  cancelled,
  refundRequested,
  refunded,
}

extension OrderStatusX on OrderStatus {
  String get label {
    switch (this) {
      case OrderStatus.pending:
        return 'Pending';
      case OrderStatus.confirmed:
        return 'Confirmed';
      case OrderStatus.preparing:
        return 'Preparing';
      case OrderStatus.readyForPickup:
        return 'Ready for Pickup';
      case OrderStatus.outForDelivery:
        return 'Out for Delivery';
      case OrderStatus.completed:
        return 'Completed';
      case OrderStatus.cancelled:
        return 'Cancelled';
      case OrderStatus.refundRequested:
        return 'Refund Requested';
      case OrderStatus.refunded:
        return 'Refunded';
    }
  }

  bool get isActive => this == OrderStatus.pending ||
      this == OrderStatus.confirmed ||
      this == OrderStatus.preparing ||
      this == OrderStatus.readyForPickup ||
      this == OrderStatus.outForDelivery;

  Color get color {
    switch (this) {
      case OrderStatus.pending:
        return AppColors.warning;
      case OrderStatus.confirmed:
        return AppColors.primary;
      case OrderStatus.preparing:
        return AppColors.primary;
      case OrderStatus.readyForPickup:
        return AppColors.success;
      case OrderStatus.outForDelivery:
        return AppColors.success;
      case OrderStatus.completed:
        return AppColors.textSecondary;
      case OrderStatus.cancelled:
        return AppColors.error;
      case OrderStatus.refundRequested:
        return AppColors.warning;
      case OrderStatus.refunded:
        return AppColors.textSecondary;
    }
  }
}

/// One line item within an [Order].
class OrderItem {
  final String productName;
  final String variantLabel;
  final int quantity;
  final double unitPrice;

  /// `products.id` / `product_variants.id` this line was ordered from.
  /// Only needed transiently, to place the order (see
  /// [OrdersRepository.createOrder] / the `place_order` RPC), which uses
  /// them to look up and decrement the exact `branch_inventory` row —
  /// `order_items` itself still stores the denormalized name/label, not
  /// these ids, matching the existing schema.
  final String? productId;
  final String? variantId;

  const OrderItem({
    required this.productName,
    required this.variantLabel,
    required this.quantity,
    required this.unitPrice,
    this.productId,
    this.variantId,
  });

  double get total => unitPrice * quantity;

  factory OrderItem.fromRow(Map<String, dynamic> row) {
    return OrderItem(
      productName: row['product_name'] as String,
      variantLabel: (row['variant_label'] as String?) ?? 'Regular',
      quantity: row['quantity'] as int,
      unitPrice: (row['unit_price'] as num).toDouble(),
    );
  }
}

/// A single step in an order's tracking timeline.
class OrderTimelineStep {
  final String label;
  final String description;
  final String time;
  final bool done;
  final bool current;

  const OrderTimelineStep({
    required this.label,
    required this.description,
    required this.time,
    this.done = false,
    this.current = false,
  });

  /// Builds the real timeline from `order_status_events` rows (oldest
  /// first) — every step here actually happened, at the time shown. There
  /// are no placeholder "upcoming" steps, since we don't know the future.
  static List<OrderTimelineStep> fromEventRows(List<Map<String, dynamic>> rows) {
    final steps = <OrderTimelineStep>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final status = OrderStatus.values.byName(row['status'] as String);
      final isLast = i == rows.length - 1;
      final createdAt = DateTime.parse(row['created_at'] as String).toLocal();
      steps.add(
        OrderTimelineStep(
          label: status.label,
          description: (row['note'] as String?) ?? 'Order ${status.label.toLowerCase()}',
          time: '${createdAt.month}/${createdAt.day} ${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}',
          done: true,
          current: isLast,
        ),
      );
    }
    return steps;
  }
}

/// A real customer order, backed 1:1 by a row in `public.orders`.
class Order {
  final String id;
  final DateTime date;
  final OrderStatus status;
  final String branch;
  final bool isDelivery;
  final List<OrderItem> items;
  final double discount;
  final double deliveryFee;
  final String paymentMethod;
  final int pointsEarned;
  final String? riderName;

  /// Rider's contact number once a rider has the order (`orders.rider_phone`).
  final String? riderPhone;
  final String? etaLabel;
  final List<OrderTimelineStep> timeline;

  /// Special instructions the customer typed at checkout (pasalubong /
  /// packing notes). Empty string, never null, since the column defaults
  /// to `''` — matches how `place_order` stores it.
  final String customerNotes;

  /// The contact number staff should call to fulfil this order — the
  /// delivery address's phone for a delivery order, or the customer's
  /// profile phone for a pickup order. Captured once, at order time, by
  /// `place_order` so it can't silently go stale if the address/profile is
  /// edited afterwards.
  final String contactPhone;

  /// Formatted delivery address as it existed when the order was placed,
  /// or null for a pickup order. Same "snapshot, not a live FK" reasoning
  /// as [contactPhone].
  final String? deliveryAddressText;

  /// Status of this order's linked `payments` row ('pending' until a real
  /// payment-gateway integration/staff action confirms it), or null if the
  /// payment row hasn't loaded yet.
  final String? paymentStatus;

  const Order({
    required this.id,
    required this.date,
    required this.status,
    required this.branch,
    required this.isDelivery,
    required this.items,
    this.discount = 0,
    required this.deliveryFee,
    required this.paymentMethod,
    required this.pointsEarned,
    this.riderName,
    this.riderPhone,
    this.etaLabel,
    this.timeline = const [],
    this.customerNotes = '',
    this.contactPhone = '',
    this.deliveryAddressText,
    this.paymentStatus,
  });

  double get subtotal => items.fold(0, (sum, i) => sum + i.total);
  double get total => subtotal - discount + deliveryFee;
  int get itemCount => items.fold(0, (sum, i) => sum + i.quantity);

  factory Order.fromRow(
    Map<String, dynamic> row, {
    required List<Map<String, dynamic>> itemRows,
    List<Map<String, dynamic>> eventRows = const [],
    Map<String, dynamic>? paymentRow,
  }) {
    return Order(
      id: row['id'] as String,
      date: DateTime.parse(row['created_at'] as String).toLocal(),
      status: OrderStatus.values.byName(row['status'] as String),
      branch: row['branch_name'] as String,
      isDelivery: row['is_delivery'] as bool,
      items: itemRows.map(OrderItem.fromRow).toList(),
      discount: (row['discount'] as num).toDouble(),
      deliveryFee: (row['delivery_fee'] as num).toDouble(),
      paymentMethod: row['payment_method'] as String,
      pointsEarned: row['points_earned'] as int,
      riderName: row['rider_name'] as String?,
      riderPhone: row['rider_phone'] as String?,
      etaLabel: row['eta_label'] as String?,
      timeline: OrderTimelineStep.fromEventRows(eventRows),
      customerNotes: (row['customer_notes'] as String?) ?? '',
      contactPhone: (row['contact_phone'] as String?) ?? '',
      deliveryAddressText: row['delivery_address_text'] as String?,
      paymentStatus: paymentRow?['status'] as String?,
    );
  }
}
