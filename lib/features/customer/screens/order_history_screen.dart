import 'package:flutter/material.dart';

import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/order.dart';
import '../widgets/category_chip.dart';
import '../widgets/order_refund_info.dart';
import '../widgets/order_status_badge.dart';
import 'order_details_screen.dart';
import 'order_tracking_screen.dart';
import 'repeat_order_screen.dart';

/// "My Orders" tab — active order tracking banner + filterable list of
/// past orders with View Details / Repeat Order actions (matches the
/// prototype's Order History & Repeat Order screen).
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

enum _Filter { all, active, completed, cancelled }

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  _Filter _filter = _Filter.all;
  final _searchController = TextEditingController();

  List<Order> get _filtered {
    var list = CustomerDataStore.instance.orders.where((o) {
      switch (_filter) {
        case _Filter.all:
          return true;
        case _Filter.active:
          return o.status.isActive;
        case _Filter.completed:
          return o.status == OrderStatus.completed;
        case _Filter.cancelled:
          return o.status == OrderStatus.cancelled;
      }
    }).toList();
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list
          .where((o) =>
      o.id.toLowerCase().contains(query) || o.branch.toLowerCase().contains(query))
          .toList();
    }
    return list;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Pull-to-refresh. Reloads real orders and tells the customer plainly if
  /// that failed (offline, expired session, ...) instead of failing silently.
  Future<void> _refresh() async {
    try {
      await AppErrors.guard(() async {
        await CustomerDataStore.instance.refresh(throwOnError: true);
      }, scope: ErrorScope.order);
    } catch (e) {
      if (!mounted) return;
      AppErrors.showSnack(context, e, scope: ErrorScope.order);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('My Orders')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: CustomerDataStore.instance,
          builder: (context, _) {
            final store = CustomerDataStore.instance;
            final orders = _filtered;
            final active = CustomerDataStore.instance.activeOrder;
            return RefreshIndicator(
              onRefresh: _refresh,
              // loading / error (+ retry) / empty / success — an empty list
              // is only shown once the load has actually finished OK.
              child: DataStateView(
              isLoading: store.isLoading,
              error: store.error,
              isEmpty: CustomerDataStore.instance.orders.isEmpty,
              onRetry: () => store.retry(),
              errorScope: ErrorScope.order,
              emptyIcon: Icons.receipt_long_outlined,
              emptyTitle: 'No orders yet',
              emptyMessage: 'Your orders will show up here once you place one.',
              loadingMessage: 'Loading your orders...',
              builder: (context) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search branch, or order ID...',
                  ),
                ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  CategoryChip(
                    label: 'All Orders (${CustomerDataStore.instance.orders.length})',
                    selected: _filter == _Filter.all,
                    onTap: () => setState(() => _filter = _Filter.all),
                  ),
                  const SizedBox(width: 8),
                  CategoryChip(
                    label: 'Active (${CustomerDataStore.instance.orders.where((o) => o.status.isActive).length})',
                    selected: _filter == _Filter.active,
                    onTap: () => setState(() => _filter = _Filter.active),
                  ),
                  const SizedBox(width: 8),
                  CategoryChip(
                    label:
                    'Completed (${CustomerDataStore.instance.orders.where((o) => o.status == OrderStatus.completed).length})',
                    selected: _filter == _Filter.completed,
                    onTap: () => setState(() => _filter = _Filter.completed),
                  ),
                  const SizedBox(width: 8),
                  CategoryChip(
                    label:
                    'Cancelled (${CustomerDataStore.instance.orders.where((o) => o.status == OrderStatus.cancelled).length})',
                    selected: _filter == _Filter.cancelled,
                    onTap: () => setState(() => _filter = _Filter.cancelled),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (active != null && (_filter == _Filter.all || _filter == _Filter.active))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.successBg,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
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
                              Text(active.id, style: AppTextStyles.titleMd),
                              Text(
                                '${active.itemCount} items • ${active.isDelivery ? 'Delivery' : 'Pickup'}',
                                style: AppTextStyles.bodySm,
                              ),
                            ],
                          ),
                          OrderStatusBadge(status: active.status),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (active.riderName != null)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.delivery_dining_rounded, color: AppColors.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(active.riderName ?? '—', style: AppTextStyles.labelLg),
                                    Text('En route from ${active.branch}', style: AppTextStyles.bodySm),
                                  ],
                                ),
                              ),
                              Text(active.etaLabel ?? '', style: AppTextStyles.labelMd),
                            ],
                          ),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('TOTAL AMOUNT', style: AppTextStyles.bodySm),
                              Text(
                                '₱${active.total.toStringAsFixed(0)}',
                                style: AppTextStyles.titleMd.copyWith(color: AppColors.primary),
                              ),
                            ],
                          ),
                          ElevatedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => OrderTrackingScreen(order: active)),
                            ),
                            icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                            label: const Text('Track Live Delivery'),
                            style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Past Orders', style: AppTextStyles.headlineSm),
                Text('${orders.where((o) => !o.status.isActive).length} Total', style: AppTextStyles.bodySm),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final order in orders.where((o) => !o.status.isActive))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _PastOrderCard(order: order),
              ),
            if (orders.where((o) => !o.status.isActive).isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No orders found.'),
                ),
              ),
              ],
              ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PastOrderCard extends StatelessWidget {
  final Order order;

  const _PastOrderCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
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
                  Text(order.id, style: AppTextStyles.titleMd),
                  Text(
                    '${order.date.month}/${order.date.day}/${order.date.year} • ${order.branch}',
                    style: AppTextStyles.bodySm,
                  ),
                ],
              ),
              OrderStatusBadge(status: order.status),
            ],
          ),
          const Divider(height: 20),
          for (final item in order.items)
            Text('${item.quantity}x ${item.productName}', style: AppTextStyles.bodyMd),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Paid via ${order.paymentMethod}', style: AppTextStyles.bodySm),
              Text(
                'Total ₱${order.total.toStringAsFixed(0)}',
                style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          if (OrderRefundInfo.appliesTo(order.status)) ...[
            const SizedBox(height: 6),
            OrderRefundInfo(orderId: order.id, status: order.status),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => OrderDetailsScreen(order: order)),
                  ),
                  child: const Text('View Details'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: order.status == OrderStatus.cancelled
                      ? null
                      : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => RepeatOrderScreen(order: order)),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Repeat Order'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
