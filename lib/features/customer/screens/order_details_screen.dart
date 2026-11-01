import 'package:flutter/material.dart';

import 'package:melai_nuts/core/config/payment_config.dart';
import 'package:melai_nuts/core/services/customer_data_store.dart';
import 'package:melai_nuts/core/theme/app_colors.dart';
import 'package:melai_nuts/core/theme/app_spacing.dart';
import 'package:melai_nuts/core/theme/app_text_styles.dart';
import 'package:melai_nuts/core/widgets/melai_app_bar.dart';
import 'package:melai_nuts/data/models/order.dart';
import 'package:melai_nuts/features/payments/screens/online_payment_screen.dart';
import 'package:melai_nuts/features/customer/widgets/order_refund_info.dart';
import 'package:melai_nuts/features/customer/widgets/order_status_badge.dart';
import 'package:melai_nuts/features/customer/screens/order_tracking_screen.dart';
import 'package:melai_nuts/features/customer/screens/repeat_order_screen.dart';

/// Full order details screen: items list, totals breakdown, payment method,
/// status timeline, and quick actions (Pay now, Track, Repeat, Request Refund).
class OrderDetailsScreen extends StatelessWidget {
  final Order order;

  const OrderDetailsScreen({super.key, required this.order});

  /// An online (HitPay) order that is not paid yet and can still be paid:
  /// the customer can reopen the payment page from here. The Edge Function
  /// re-checks all of this server-side.
  bool get _canPayOnline {
    if (!PaymentConfig.onlinePaymentEnabled || !PaymentConfig.isOnlinePayment(order.paymentMethod)) return false;
    if (order.status == OrderStatus.cancelled ||
        order.status == OrderStatus.refundRequested ||
        order.status == OrderStatus.refunded) {
      return false;
    }
    final status = CustomerDataStore.instance.paymentForOrder(order.id)?.status.name ?? order.paymentStatus;
    return status == null || status == 'pending' || status == 'processing' || status == 'failed';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Order #${order.id.length > 8 ? order.id.substring(0, 8) : order.id}',
        showBack: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            // Header Card: ID, Date, Status
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ORDER ID',
                              style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted),
                            ),
                            Text(order.id, style: AppTextStyles.titleMd),
                          ],
                        ),
                      ),
                      OrderStatusBadge(status: order.status),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('BRANCH', style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted)),
                            Text(order.branch, style: AppTextStyles.bodyMd),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('DATE', style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted)),
                            Text(
                              '${order.date.month}/${order.date.day}/${order.date.year}',
                              style: AppTextStyles.bodyMd,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PAYMENT METHOD', style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted)),
                            Text(order.paymentMethod, style: AppTextStyles.bodyMd),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('TYPE', style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted)),
                            Text(
                              order.isDelivery ? 'Delivery' : 'Store Pickup',
                              style: AppTextStyles.bodyMd,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Refunded / pending amount and points reversed, from the database.
                  if (OrderRefundInfo.appliesTo(order.status)) ...[
                    const Divider(height: 24),
                    OrderRefundInfo(orderId: order.id, status: order.status),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Items Card
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ORDER ITEMS', style: AppTextStyles.labelLg),
                  const Divider(height: 20),
                  for (final item in order.items) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${item.quantity}x',
                              style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.productName, style: AppTextStyles.labelLg),
                                if (item.variantLabel.isNotEmpty)
                                  Text(
                                    item.variantLabel,
                                    style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '₱${(item.unitPrice * item.quantity).toStringAsFixed(0)}',
                            style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Order Summary Totals
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PAYMENT SUMMARY', style: AppTextStyles.labelLg),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Subtotal', style: AppTextStyles.bodyMd),
                      Text('₱${order.subtotal.toStringAsFixed(0)}', style: AppTextStyles.bodyMd),
                    ],
                  ),
                  if (order.discount > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Discount', style: AppTextStyles.bodyMd.copyWith(color: AppColors.success)),
                        Text('-₱${order.discount.toStringAsFixed(0)}', style: AppTextStyles.bodyMd.copyWith(color: AppColors.success)),
                      ],
                    ),
                  ],
                  if (order.isDelivery) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Delivery Fee', style: AppTextStyles.bodyMd),
                        Text('₱${order.deliveryFee.toStringAsFixed(0)}', style: AppTextStyles.bodyMd),
                      ],
                    ),
                  ],
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('TOTAL PAID', style: AppTextStyles.titleMd),
                      Text(
                        '₱${order.total.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Action Buttons
            if (_canPayOnline) ...[
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => OnlinePaymentScreen(order: order, itemCount: order.itemCount, resume: true),
                  ),
                ),
                icon: const Icon(Icons.account_balance_wallet_rounded),
                label: const Text('Pay Now'),
              ),
              const SizedBox(height: 10),
            ],
            if (order.status.isActive)
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => OrderTrackingScreen(order: order)),
                ),
                icon: const Icon(Icons.local_shipping_outlined),
                label: const Text('Track Order Status'),
              ),
            if (!order.status.isActive && order.status != OrderStatus.cancelled) ...[
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => RepeatOrderScreen(order: order)),
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Repeat Order'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
