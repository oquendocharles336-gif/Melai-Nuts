import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/inventory_item.dart';
import '../../../data/models/order.dart';
import '../../../data/models/staff_models.dart';
import '../../../data/repositories/products_repository.dart';
import '../../inventory/screens/inventory_dashboard_screen.dart';
import '../../settings/screens/logout_confirmation_screen.dart';
import '../barcode/barcode_scan_screen.dart';
import '../barcode/sku_matcher.dart';
import '../widgets/pos_offline_widgets.dart';
import 'cash_drawer_screen.dart';
import 'staff_dashboard_tab.dart';
import 'staff_extra_screens.dart';

/// Branch Staff Portal — Home (dashboard), Register (POS), Orders, Inventory
/// (FEFO) and Profile (incl. Log Out). All data comes from the database via
/// [StaffStore]; the database decides what this account may see and do.
class StaffPortalScreen extends StatefulWidget {
  const StaffPortalScreen({super.key});

  @override
  State<StaffPortalScreen> createState() => _StaffPortalScreenState();
}

class _StaffPortalScreenState extends State<StaffPortalScreen> {
  final StaffStore _store = StaffStore.instance;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _store.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final profile = _store.profile;
        if (profile == null) return _buildGate();

        final branchLabel = _store.activeBranchName;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: AppBar(
            title: Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.roleStaff,
                  child: Icon(Icons.badge_rounded, size: 16, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Staff Portal', style: AppTextStyles.labelLg),
                      Text(
                        branchLabel.isEmpty ? profile.roleLabel : '${profile.roleLabel} • $branchLabel',
                        style: AppTextStyles.bodySm,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              if (profile.isOwner && kBranches.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Switch branch',
                  icon: const Icon(Icons.storefront_outlined),
                  onSelected: _store.setOwnerBranch,
                  itemBuilder: (_) => [
                    for (final b in kBranches)
                      CheckedPopupMenuItem<String>(
                        value: b.id,
                        checked: b.id == _store.activeBranchId,
                        child: Text(b.name),
                      ),
                  ],
                ),
              // Delivery runs for this branch (create, assign a driver, dispatch,
              // live map). The admin website has no delivery function.
              IconButton(
                tooltip: 'Deliveries',
                icon: const Icon(Icons.local_shipping_outlined),
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDashboard),
              ),
              IconButton(
                tooltip: 'Cash drawer',
                icon: const Icon(Icons.point_of_sale_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CashDrawerScreen()),
                ),
              ),
              IconButton(
                tooltip: 'Notifications',
                icon: Badge(
                  isLabelVisible: _store.unreadNotifications > 0,
                  label: Text('${_store.unreadNotifications}'),
                  child: const Icon(Icons.notifications_none_rounded),
                ),
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.staffNotifications),
              ),
            ],
          ),
          body: IndexedStack(
            index: _currentIndex,
            children: [
              StaffDashboardTab(onOpenTab: (i) => setState(() => _currentIndex = i)),
              const _PosRegisterTab(),
              const _TransactionsTab(),
              const InventoryDashboardBody(),
              const StaffProfileBody(),
            ],
          ),
          bottomNavigationBar: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.white,
              indicatorColor: AppColors.roleStaff.withValues(alpha: 0.15),
              surfaceTintColor: Colors.transparent,
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return AppTextStyles.labelMd.copyWith(color: AppColors.roleStaff);
                }
                return AppTextStyles.labelMd;
              }),
            ),
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) => setState(() => _currentIndex = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded, color: AppColors.roleStaff),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.point_of_sale_outlined),
                  selectedIcon: Icon(Icons.point_of_sale_rounded, color: AppColors.roleStaff),
                  label: 'Register',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long_rounded, color: AppColors.roleStaff),
                  label: 'Orders',
                ),
                NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  selectedIcon: Icon(Icons.inventory_2_rounded, color: AppColors.roleStaff),
                  label: 'Inventory',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded, color: AppColors.roleStaff),
                  label: 'Profile',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shown until the account is verified against the staff registry. An
  /// account that is not (or no longer) registered as staff is stopped here
  /// with the database's own explanation.
  Widget _buildGate() {
    final failed = _store.profileState.error != null;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Staff Portal')),
      body: failed
          ? Column(
              children: [
                Expanded(child: StateErrorView(error: _store.profileState.error, onRetry: _store.start)),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen()),
                    ),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Log Out'),
                  ),
                ),
              ],
            )
          : const StateLoadingView(message: 'Loading your branch…'),
    );
  }
}

// ---------------------------------------------------------------------------
// Register (POS)
// ---------------------------------------------------------------------------

class _PosRegisterTab extends StatefulWidget {
  const _PosRegisterTab();

  @override
  State<_PosRegisterTab> createState() => _PosRegisterTabState();
}

class _PosRegisterTabState extends State<_PosRegisterTab> {
  String? _categoryId; // null = all
  final Map<String, int> _cart = {}; // variantId -> quantity
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  double _total(StaffStore store) {
    double sum = 0;
    _cart.forEach((variantId, qty) {
      final item = store.itemByVariant(variantId);
      if (item != null) sum += item.price * qty;
    });
    return sum;
  }

  void _add(InventoryItem item) {
    final qty = _cart[item.variantId] ?? 0;
    if (qty + 1 > item.quantity) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Only ${item.quantity} of ${item.displayName} in stock.')));
      return;
    }
    setState(() => _cart[item.variantId] = qty + 1);
  }

  /// Barcode scanners "type" the code then press Enter: an exact SKU match
  /// adds that product.
  /// A keyboard-wedge scanner (or typed SKU + Enter) and the camera scanner
  /// both end here: an exact SKU match adds the item; anything else says so.
  void _submitSearch(StaffStore store, String value, {bool fromScanner = false}) {
    if (value.trim().isEmpty) return;
    final item = matchSku(store.inventoryItems, value);
    if (item != null) {
      _add(item);
      setState(() => _searchController.clear());
      return;
    }
    if (fromScanner) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No product at this branch has the code "${value.trim()}". Search by name instead.')),
      );
    }
  }

  Future<void> _scan(StaffStore store) async {
    final code = await BarcodeScanScreen.open(context);
    if (code == null || !mounted) return;
    _submitSearch(store, code, fromScanner: true);
  }

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, ProductsRepository.instance]),
      builder: (context, _) {
        // Drop cart lines whose product no longer exists after a refresh.
        if (store.inventoryState.loaded) {
          _cart.removeWhere((id, qty) => store.itemByVariant(id) == null);
        }

        final query = _searchController.text.trim().toLowerCase();
        var items = store.inventoryItems.toList();
        if (_categoryId != null) items = items.where((i) => i.categoryId == _categoryId).toList();
        if (query.isNotEmpty) {
          items = items
              .where((i) => i.displayName.toLowerCase().contains(query) || i.sku.toLowerCase().contains(query))
              .toList();
        }

        return Column(
          children: [
            const PosQueueBanner(),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() {}),
                onSubmitted: (v) => _submitSearch(store, v),
                decoration: InputDecoration(
                  hintText: 'Scan barcode or search name / SKU...',
                  prefixIcon: IconButton(
                    tooltip: 'Scan a barcode with the camera',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: () => _scan(store),
                  ),
                  suffixIcon: query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () => setState(() => _searchController.clear()),
                        )
                      : const Icon(Icons.search_rounded),
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                children: [
                  _chip('All', _categoryId == null, () => setState(() => _categoryId = null)),
                  for (final c in kProductCategories)
                    _chip(c.name, _categoryId == c.id, () => setState(() => _categoryId = c.id)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: RefreshIndicator(
                onRefresh: store.refreshInventory,
                child: DataStateView(
                  isLoading: store.inventoryState.busy,
                  error: store.inventoryState.error,
                  isEmpty: items.isEmpty,
                  onRetry: store.refreshInventory,
                  emptyIcon: Icons.point_of_sale_outlined,
                  emptyTitle: query.isEmpty ? 'No products to sell.' : 'No products match your search.',
                  emptyMessage: query.isEmpty ? 'This branch has no products in stock yet. Add products under Products, then record stock with Receive Stock.' : null,
                  builder: (context) => _grid(items),
                ),
              ),
            ),
            if (_cart.isNotEmpty) _checkoutBar(store),
          ],
        );
      },
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppColors.roleStaff.withValues(alpha: 0.2),
        labelStyle: AppTextStyles.labelMd.copyWith(color: selected ? AppColors.roleStaff : null),
      ),
    );
  }

  Widget _grid(List<InventoryItem> items) {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final product = findProductById(item.productId);
        final qty = _cart[item.variantId] ?? 0;
        final isSelected = qty > 0;
        final out = item.isOutOfStock;

        return Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: out ? 0.5 : 1,
              child: InkWell(
                onTap: out ? null : () => _add(item),
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.roleStaff.withValues(alpha: 0.04) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected ? AppColors.roleStaff : AppColors.border,
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: isSelected ? null : AppShadows.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(product.icon, size: 22, color: isSelected ? AppColors.roleStaff : product.color),
                      const Spacer(),
                      Text(
                        item.productName,
                        style: AppTextStyles.labelMd.copyWith(
                          color: isSelected ? AppColors.roleStaff : null,
                          fontWeight: isSelected ? FontWeight.bold : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.variantLabel.isNotEmpty)
                        Text(item.variantLabel, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Row(
                        children: [
                          Text(
                            pesoWhole(item.price),
                            style: AppTextStyles.bodySm.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isSelected ? AppColors.roleStaff : AppColors.textSecondary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            out ? 'Out' : '${item.quantity} left',
                            style: AppTextStyles.labelSm.copyWith(
                              color: out || item.isLowStock ? AppColors.error : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isSelected)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () => setState(() {
                        if (qty > 1) {
                          _cart[item.variantId] = qty - 1;
                        } else {
                          _cart.remove(item.variantId);
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                        child: const Icon(Icons.remove, size: 14, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: AppColors.roleStaff, borderRadius: BorderRadius.circular(12)),
                      child: Text(
                        '$qty',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _checkoutBar(StaffStore store) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -4))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TRANSACTION TOTAL', style: AppTextStyles.bodySm),
                  Text(peso(_total(store)), style: AppTextStyles.headlineSm.copyWith(color: AppColors.roleStaff)),
                ],
              ),
            ),
            SizedBox(
              width: 140,
              child: PrimaryButton(
                label: 'Checkout',
                onPressed: () async {
                  final result = await Navigator.of(context)
                      .pushNamed(AppRoutes.staffPosCart, arguments: Map<String, int>.from(_cart));
                  // The checkout flow returns true once a sale was recorded.
                  if (mounted && result == true) setState(_cart.clear);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------

enum _OrderFilter { active, today, all }

class _TransactionsTab extends StatefulWidget {
  const _TransactionsTab();

  @override
  State<_TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<_TransactionsTab> {
  _OrderFilter _filter = _OrderFilter.active;

  String _filterLabel(_OrderFilter f) {
    switch (f) {
      case _OrderFilter.active:
        return 'Active';
      case _OrderFilter.today:
        return 'Today';
      case _OrderFilter.all:
        return 'Recent';
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final orders = store.orders.where((o) {
          switch (_filter) {
            case _OrderFilter.active:
              return o.status.isActive;
            case _OrderFilter.today:
              return isToday(o.createdAt);
            case _OrderFilter.all:
              return true;
          }
        }).toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
              child: Row(
                children: [
                  for (final f in _OrderFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_filterLabel(f)),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                        selectedColor: AppColors.roleStaff.withValues(alpha: 0.2),
                        labelStyle: AppTextStyles.labelMd.copyWith(color: _filter == f ? AppColors.roleStaff : null),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: store.refreshOrders,
                child: DataStateView(
                  isLoading: store.ordersState.busy,
                  error: store.ordersState.error,
                  isEmpty: orders.isEmpty,
                  onRetry: store.refreshOrders,
                  emptyIcon: Icons.receipt_long_outlined,
                  emptyTitle: _filter == _OrderFilter.active
                      ? 'No active orders.'
                      : (_filter == _OrderFilter.today ? 'No orders today.' : 'No orders yet.'),
                  emptyMessage: 'New orders and sales appear here as they happen.',
                  builder: (context) => ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: orders.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _OrderCard(order: orders[i]),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  final StaffOrder order;

  const _OrderCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final o = order;
    return InkWell(
      onTap: () => Navigator.of(context).pushNamed(AppRoutes.staffTransactionDetails, arguments: o),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(o.id, style: AppTextStyles.labelLg),
                _StatusChip(status: o.status),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                const Icon(Icons.person_outline_rounded, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Expanded(child: Text(o.customerLabel, style: AppTextStyles.bodyMd, overflow: TextOverflow.ellipsis)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(peso(o.total), style: AppTextStyles.labelLg),
                    // Refunded / pending amounts come from the database (refund_summary).
                    if (o.refund != null && o.refund!.isRefunded)
                      Text('-${peso(o.refund!.refundedAmount)} refunded', style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                    if (o.refund != null && o.refund!.hasPending)
                      Text('${peso(o.refund!.pendingAmount)} refund pending', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.access_time_rounded, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${friendlyTime(o.createdAt)} • ${o.channelLabel} • '
                    '${o.refund?.label ?? (o.isPaid || o.payment?.status == 'refunded' ? 'Paid' : 'Payment pending')}',
                    style: AppTextStyles.bodySm,
                  ),
                ),
                if (o.isDelivery) _PinIndicator(orderId: o.id),
                const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textSecondary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final OrderStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: status.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(status.label, style: AppTextStyles.labelSm.copyWith(color: status.color)),
    );
  }
}


/// Small map-pin icon on a delivery order: green when the customer pinned the
/// location, amber when they did not. Nothing while pins are unknown.
class _PinIndicator extends StatelessWidget {
  final String orderId;
  const _PinIndicator({required this.orderId});

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    if (!store.deliveryPinsLoaded) return const SizedBox.shrink();
    final pinned = store.deliveryPins[orderId]?.isPinned ?? false;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: pinned ? 'Customer pinned the delivery location' : "No map pin — call the customer",
        child: Icon(
          pinned ? Icons.location_on_rounded : Icons.wrong_location_outlined,
          size: 18,
          color: pinned ? AppColors.success : AppColors.warning,
        ),
      ),
    );
  }
}
