import 'package:flutter/material.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/list_tools.dart';
import '../../../data/models/order.dart';
import '../../../data/repositories/orders_repository.dart';
import '../widgets/order_refund_info.dart';
import '../widgets/order_status_badge.dart';
import 'order_details_screen.dart';
import 'order_tracking_screen.dart';
import 'repeat_order_screen.dart';
import '../../../l10n/generated/app_localizations.dart';

/// "My Orders" tab — active order tracking banner + a searchable, sortable,
/// filterable order history read page by page from the server (25 at a
/// time, infinite scroll). Offline, the copy saved on this device is
/// searched instead and labelled "Saved data · last updated …".
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  DateTime? _savedAt;
  late final PagedListController<Order> _paged = PagedListController<Order>(
    fetch: _fetch,
    query: const ListQuery(sortId: 'newest'),
  );

  Future<PageResult<Order>> _fetch(ListQuery query, int offset, int limit) async {
    final uid = AuthService.instance.currentFirebaseUser?.uid;
    if (uid == null) return const PageResult([], 0);
    try {
      final page = await OrdersRepository.instance.fetchOrdersPage(uid, query, offset, limit);
      if (offset == 0 && _savedAt != null && mounted) setState(() => _savedAt = null);
      return page;
    } catch (_) {
      if (ConnectivityService.instance.isOnline) rethrow;
      final (page, savedAt) = await OrdersRepository.instance.localOrdersPage(uid, query, offset, limit);
      if (page.total == 0 && !query.isNarrowed) rethrow;
      if (mounted) setState(() => _savedAt = savedAt);
      return page;
    }
  }

  List<SortOption<Order>> _sorts(AppLocalizations t) => [
        SortOption('newest', t.sortNewest, null),
        SortOption('oldest', t.sortOldest, null),
        SortOption('totalHigh', t.sortAmountHigh, null),
        SortOption('totalLow', t.sortAmountLow, null),
      ];

  List<FilterGroup<Order>> _groups(AppLocalizations t) => [
        FilterGroup('status', t.filterStatus, [
          FilterChoice('active', t.statusActiveOrders, null),
          FilterChoice('completed', t.statusCompleted, null),
          FilterChoice('cancelled', t.statusCancelled, null),
          FilterChoice('refunded', t.statusRefunded, null),
        ]),
        FilterGroup('date', t.filterDate, [
          FilterChoice('7', t.last7Days, null),
          FilterChoice('30', t.last30Days, null),
          FilterChoice('90', t.last90Days, null),
        ]),
      ];

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _openSortFilter() async {
    final t = AppLocalizations.of(context);
    final next = await SortFilterSheet.show<Order>(
      context,
      query: _paged.query,
      sorts: _sorts(t),
      groups: _groups(t),
    );
    if (next != null && mounted) _paged.setQuery(next);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('My Orders')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([CustomerDataStore.instance, _paged]),
          builder: (context, _) {
            final active = CustomerDataStore.instance.activeOrder;
            final query = _paged.query;
            return PagedListView<Order>(
              controller: _paged,
              errorScope: ErrorScope.order,
              emptyIcon: Icons.receipt_long_outlined,
              emptyTitle: t.noOrdersYet,
              emptyMessage: t.noOrdersYetMessage,
              onClearQuery: () => _paged.setQuery(const ListQuery(sortId: 'newest')),
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_savedAt != null) ...[
                    LastUpdatedBanner(savedAt: _savedAt),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  AppSearchBar(
                    hint: 'Search branch, or order ID...',
                    initialValue: query.search,
                    onChanged: (text) => _paged.setQuery(query.copyWith(search: text)),
                    trailing: SortFilterButton(
                      active: query.hasFilters || query.sortId != 'newest',
                      onPressed: _openSortFilter,
                    ),
                  ),
                  ActiveFilterChips<Order>(
                    query: query,
                    groups: _groups(t),
                    onChanged: _paged.setQuery,
                  ),
                  if (active != null && !query.isNarrowed) ...[
                    const SizedBox(height: AppSpacing.md),
                    _ActiveOrderBanner(active: active),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Orders', style: AppTextStyles.headlineSm),
                      if (_paged.total > 0) Text(t.resultsCount(_paged.total), style: AppTextStyles.bodySm),
                    ],
                  ),
                ],
              ),
              itemBuilder: (context, order) => _PastOrderCard(order: order),
            );
          },
        ),
      ),
    );
  }
}

class _ActiveOrderBanner extends StatelessWidget {
  const _ActiveOrderBanner({required this.active});

  final Order active;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
