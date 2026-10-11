import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/services/push_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/order.dart';
import 'customer_portal_screen.dart';
import 'order_tracking_screen.dart';

/// "Order Confirmed" success screen shown right after checkout.
class OrderConfirmationScreen extends StatelessWidget {
  final Order order;
  final int itemCount;
  final double total;

  const OrderConfirmationScreen({super.key, required this.order, required this.itemCount, required this.total});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      // The first order is the moment notification permission is asked for
      // (with an explanation first), never at app start.
      body: AskNotificationsOnce(
        onGranted: PushService.instance.registerIfAllowed,
        child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: const BoxDecoration(color: AppColors.successBg, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: AppColors.success, size: 44),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(color: AppColors.successBg, borderRadius: BorderRadius.circular(20)),
                child: Text('ORDER CONFIRMED', style: AppTextStyles.labelMd.copyWith(color: AppColors.success)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Salamat po! Your\nOrder is Confirmed',
              textAlign: TextAlign.center,
              style: AppTextStyles.headlineLg.copyWith(color: AppColors.darkBrown),
            ),
            const SizedBox(height: 8),
            Text(
              'Order ${order.id} has been received by ${order.branch} and is now being freshly packed.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd,
            ),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ORDER REFERENCE', style: AppTextStyles.labelSm),
                          Text(order.id, style: AppTextStyles.titleMd.copyWith(color: AppColors.primary)),
                        ],
                      ),
                      OutlinedButton.icon(
                        // Really copies the order number (it used to do nothing).
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: order.id));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Order number copied.')));
                        },
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  _InfoRow(
                    icon: Icons.storefront_outlined,
                    label: 'Fulfillment Type',
                    value: order.isDelivery ? 'Home Delivery' : 'In-Store Express Pickup',
                  ),
                  _InfoRow(
                    icon: order.isDelivery ? Icons.location_on_outlined : Icons.storefront_outlined,
                    label: order.isDelivery ? 'Delivery Address' : 'Pickup Location',
                    value: order.isDelivery
                        ? (order.deliveryAddressText?.isNotEmpty == true
                            ? order.deliveryAddressText!
                            : 'Address on file')
                        : 'Melai Nuts ${order.branch}',
                  ),
                  if (order.contactPhone.isNotEmpty)
                    _InfoRow(
                      icon: Icons.call_outlined,
                      label: 'Contact Number',
                      value: order.contactPhone,
                    ),
                  _InfoRow(
                    icon: Icons.payments_outlined,
                    label: 'Payment',
                    value: order.paymentStatus == 'success'
                        ? '${order.paymentMethod} • Paid'
                        : '${order.paymentMethod} • Awaiting confirmation',
                  ),
                  if (order.customerNotes.isNotEmpty)
                    _InfoRow(
                      icon: Icons.sticky_note_2_outlined,
                      label: 'Special Instructions',
                      value: order.customerNotes,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Row(
                children: [
                  const Icon(Icons.stars_rounded, color: AppColors.primaryDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '+${order.pointsEarned} Golden Kernel Points Added!',
                      style: AppTextStyles.labelLg.copyWith(color: AppColors.primaryDark),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order Summary ($itemCount items)', style: AppTextStyles.titleMd),
                  const SizedBox(height: 10),
                  for (final item in order.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text('${item.quantity}x ${item.productName}', style: AppTextStyles.bodyMd),
                          ),
                          Text('₱${item.total.toStringAsFixed(0)}', style: AppTextStyles.bodyMd),
                        ],
                      ),
                    ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total Paid', style: AppTextStyles.headlineSm),
                      Text(
                        '₱${total.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Track Live Order Progress',
              icon: Icons.local_shipping_outlined,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => OrderTrackingScreen(order: order)),
              ),
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Continue Shopping',
              onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const CustomerPortalScreen()),
                    (route) => false,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.bodySm),
                Text(value, style: AppTextStyles.labelLg),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
