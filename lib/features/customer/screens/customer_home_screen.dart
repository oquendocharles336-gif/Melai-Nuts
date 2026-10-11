import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/motion.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/services/customer_data_store.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/notification_item.dart';
import '../../../data/models/order.dart';
import '../../../data/models/product.dart';
import '../../../data/models/promotion.dart';
import '../../../data/repositories/products_repository.dart';
import '../../settings/screens/branch_settings_screen.dart';
import '../cart_controller.dart';
import '../widgets/category_chip.dart';
import '../widgets/order_status_badge.dart';
import '../widgets/product_card.dart';
import 'cart_screen.dart';
import 'order_tracking_screen.dart';
import 'product_catalog_screen.dart';
import 'product_categories_screen.dart';
import 'product_details_screen.dart';
import 'search_results_screen.dart';

/// "Store Home" — branch selector, search, featured promos, categories,
/// and popular products (matches the prototype's Customer Home screen).
class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  /// null = "All". Otherwise a real `product_categories.id` from Supabase.
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    // Catalog is preloaded at app boot; only re-fetch here if that hasn't
    // succeeded yet (e.g. cold start was offline). Loading / error / retry
    // state is read from ProductsRepository in build().
    final catalog = ProductsRepository.instance;
    if (!catalog.hasLoaded && !catalog.isLoading) _retryCatalog();
  }

  Future<void> _retryCatalog() => ProductsRepository.instance.loadCatalog(
        branchId: BranchController.instance.selectedBranch?.id,
      );

  /// The dashboard's "Popular Near You" strip, ranked by real sales
  /// ([kPopularProducts]; falls further back inside the repository), then
  /// narrowed to the selected category chip, if any.
  List<Product> get _visiblePopularProducts {
    final source = kPopularProducts.isNotEmpty ? kPopularProducts : kProducts;
    final categoryId = _selectedCategoryId;
    if (categoryId == null) return source.take(8).toList();
    return source.where((p) => p.categoryId == categoryId).take(8).toList();
  }

  /// Staff/owner-curated picks (`products.is_featured`), shown as their own
  /// row regardless of real sales ranking — distinct from "Popular Near
  /// You" so a featured product doesn't disappear once real sales exist
  /// (see `ProductsRepository._loadPopularProducts`'s fallback logic).
  List<Product> get _featuredProducts => kProducts.where((p) => p.isFeatured).take(8).toList();

  /// Orders that are placed but not yet completed/cancelled.
  List<Order> get _activeOrders =>
      CustomerDataStore.instance.orders.where((o) => o.status.isActive).toList()..sort((a, b) => b.date.compareTo(a.date));

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Filipino time-of-day greeting.
  String _timeGreeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Magandang umaga';
    if (h < 18) return 'Magandang hapon';
    return 'Magandang gabi';
  }

  static const double _cardWidth = 172;
  static const double _stripHeight = 296;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        CustomerDataStore.instance,
        ProductsRepository.instance,
      ]),
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _pad(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: child,
      );

  Widget _sectionHeader(String title, {String? action, VoidCallback? onAction, IconData? icon}) {
    return _pad(
      Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: AppColors.primary),
            const SizedBox(width: 6),
          ],
          Expanded(child: Text(title, style: AppTextStyles.headlineSm.copyWith(color: AppColors.darkBrown))),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action),
                  const SizedBox(width: 2),
                  const Icon(Icons.arrow_forward_rounded, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    required int badgeCount,
  }) {
    return Badge(
      label: Text(badgeCount.toString()),
      isLabelVisible: badgeCount > 0,
      backgroundColor: AppColors.warning,
      textColor: Colors.white,
      child: Material(
        color: Colors.white.withValues(alpha: 0.18),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  /// Warm gradient hero: greeting, cart / notifications, branch pill, search.
  Widget _buildHeader(BuildContext context, String greeting, int unreadCount) {
    final top = MediaQuery.paddingOf(context).top;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6B3F1E), AppColors.primary, Color(0xFFC48A55)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -40,
              top: -30,
              child: Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.07),
                ),
              ),
            ),
            Positioned(
              left: -50,
              bottom: -60,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.md, top + 14, AppSpacing.md, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MELAI NUTS LAGUNA',
                              style: AppTextStyles.labelSm.copyWith(
                                color: Colors.white.withValues(alpha: 0.75),
                                letterSpacing: 1.6,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              greeting,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.headlineMd.copyWith(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      ListenableBuilder(
                        listenable: CartController.instance,
                        builder: (context, _) => _headerIconButton(
                          icon: Icons.shopping_bag_outlined,
                          badgeCount: CartController.instance.itemCount,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const CartScreen()),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _headerIconButton(
                        icon: Icons.notifications_none_rounded,
                        badgeCount: unreadCount,
                        onPressed: () => Navigator.of(context).pushNamed(AppRoutes.notificationCenter),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ListenableBuilder(
                    listenable: BranchController.instance,
                    builder: (context, _) {
                      final branch = BranchController.instance.selectedBranch;
                      return Material(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const BranchSettingsScreen()),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.location_on_rounded, size: 18, color: AppColors.primary),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        branch != null ? branch.name : 'Choose your branch',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTextStyles.labelLg.copyWith(color: Colors.white),
                                      ),
                                      Text(
                                        branch != null ? branch.address : 'Pick one to see what\'s in stock',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTextStyles.bodySm.copyWith(
                                          color: Colors.white.withValues(alpha: 0.8),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  'Change',
                                  style: AppTextStyles.labelLg.copyWith(color: Colors.white),
                                ),
                                const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: AppShadows.md,
                    ),
                    child: TextField(
                      textInputAction: TextInputAction.search,
                      onSubmitted: (q) => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => SearchResultsScreen(query: q)),
                      ),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                        hintText: 'Search for garlic, spicy, or sweet...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: AppColors.primaryContainer, width: 2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeOrderCard(BuildContext context, Order order) {
    final shortId = (order.id.length >= 8 ? order.id.substring(0, 8) : order.id).toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => OrderTrackingScreen(order: order)),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.local_shipping_rounded, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Order #$shortId', style: AppTextStyles.labelLg),
                    const SizedBox(height: 2),
                    Text(
                      '${order.itemCount} item${order.itemCount == 1 ? '' : 's'}  •  ₱${order.total.toStringAsFixed(0)}',
                      style: AppTextStyles.bodySm,
                    ),
                  ],
                ),
              ),
              OrderStatusBadge(status: order.status),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _promoCard(BuildContext context, Promotion promo) {
    return Container(
      width: MediaQuery.sizeOf(context).width - (AppSpacing.md * 2) - 28,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, Color(0xFF5E3519)],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        boxShadow: AppShadows.md,
      ),
      child: Stack(
        children: [
          Positioned(
            right: -24,
            bottom: -28,
            child: Icon(
              promo.icon,
              size: 150,
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.warning,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    promo.badgeLabel,
                    style: AppTextStyles.labelSm.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  promo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.headlineMd.copyWith(color: Colors.white),
                ),
                if (promo.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    promo.subtitle,
                    style: AppTextStyles.bodyMd.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _productStrip(List<Product> items) {
    final cart = CartController.instance;
    return SizedBox(
      height: _stripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final product = items[index];
          final defaultVariant = product.variants.first;
          // Horizontal lists give children unbounded width, so each card
          // needs an explicit one.
          return SizedBox(
            width: _cardWidth,
            child: ProductCard(
              product: product,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ProductDetailsScreen(product: product)),
              ),
              onAdd: () => addToCartWithFeedback(context, product, defaultVariant),
              quantityInCart: cart.quantityFor(product.id, defaultVariant.label),
            ),
          );
        },
      ),
    );
  }

  Widget _rewardsCard(BuildContext context, int points) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A2C18), Color(0xFF8A5530)],
        ),
        boxShadow: AppShadows.md,
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
            ),
            child: const Icon(Icons.workspace_premium_rounded, color: Color(0xFFFFD27A), size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Golden Kernel Rewards',
                  style: AppTextStyles.labelLg.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$points',
                      style: AppTextStyles.headlineLg.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'pts available',
                        style: AppTextStyles.bodySm.copyWith(color: Colors.white.withValues(alpha: 0.75)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.customerLoyaltyDashboard),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.darkBrown,
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('View'),
          ),
        ],
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final store = CustomerDataStore.instance;
    final firstName = (store.profile?.fullName ?? '').trim().split(' ').first;
    final greeting = firstName.isEmpty ? '${_timeGreeting()}!' : '${_timeGreeting()}, $firstName!';
    final unreadCount = store.notifications.where((n) => !n.read).length;
    final catalog = ProductsRepository.instance;

    var step = 0;
    Duration next() => Duration(milliseconds: 90 * (step++));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          children: [
            _buildHeader(context, greeting, unreadCount),
            // Loading indicator while the catalog or the customer's records
            // are being fetched, so the screen never looks silently blank.
            if (store.isLoading || catalog.isLoading)
              _pad(
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(minHeight: 3),
                  ),
                ),
              ),
            // Customer records (orders / notifications / points) failed to
            // load: say so, with a retry, instead of hiding the sections.
            if (store.error != null && !store.isLoading)
              _pad(
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.sm,
                    ),
                    child: StateErrorView(
                      compact: true,
                      error: store.error,
                      message: 'We couldn\'t load your orders and notifications.',
                      onRetry: () => store.retry(),
                    ),
                  ),
                ),
              ),
            // Active Orders — real, from `orders`/`order_status_events`.
            // Hidden entirely when there's nothing in progress.
            if (_activeOrders.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn(
                delay: next(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader('Active Orders', icon: Icons.delivery_dining_rounded),
                    const SizedBox(height: AppSpacing.xs),
                    _pad(
                      Column(
                        children: [
                          for (final order in _activeOrders) _activeOrderCard(context, order),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Most recent notification — real, from `notifications`.
            // Hidden when the customer has none at all.
            if (store.notifications.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              FadeSlideIn(
                delay: next(),
                child: _pad(
                  Builder(builder: (context) {
                    final latest = store.notifications.first;
                    return Pressable(
                      onTap: () => Navigator.of(context).pushNamed(AppRoutes.notificationCenter),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: latest.read ? Colors.white : AppColors.primaryContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: latest.category.color.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(latest.category.icon, color: latest.category.color, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(latest.title,
                                      style: AppTextStyles.labelLg, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(latest.body,
                                      style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(_relativeTime(latest.time), style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ],
            // Promo banner(s) — real, staff-managed rows from
            // `promotions`. No section at all when there isn't a current
            // one, rather than a made-up offer.
            if (kPromotions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn(
                delay: next(),
                child: SizedBox(
                  height: 184,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 4),
                    itemCount: kPromotions.length,
                    separatorBuilder: (context, index) => const SizedBox(width: 12),
                    itemBuilder: (context, index) => _promoCard(context, kPromotions[index]),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            // Category Picker — real categories from `product_categories`.
            FadeSlideIn(
              delay: next(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    'Categories',
                    action: 'See all',
                    onAction: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ProductCategoriesScreen()),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                      children: [
                        CategoryChip(
                          label: 'All',
                          selected: _selectedCategoryId == null,
                          onTap: () => setState(() => _selectedCategoryId = null),
                        ),
                        for (final category in kProductCategories) ...[
                          const SizedBox(width: 8),
                          CategoryChip(
                            label: category.name,
                            selected: _selectedCategoryId == category.id,
                            onTap: () => setState(() => _selectedCategoryId = category.id),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Featured Section — staff/owner-curated picks
            // (`products.is_featured`), always shown when any exist,
            // independent of the sales-ranked "Popular" row below.
            if (_featuredProducts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              FadeSlideIn(
                delay: next(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionHeader('Featured for You', icon: Icons.auto_awesome_rounded),
                    const SizedBox(height: AppSpacing.xs),
                    ListenableBuilder(
                      listenable: Listenable.merge([CartController.instance, BranchController.instance]),
                      builder: (context, _) => _productStrip(_featuredProducts),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            // Popular Section — ranked by real units sold (falls back to
            // staff-featured, then newest, only if nothing's sold yet).
            FadeSlideIn(
              delay: next(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    'Popular Near You',
                    icon: Icons.local_fire_department_rounded,
                    action: 'See all',
                    onAction: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ProductCatalogScreen()),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  ListenableBuilder(
                    // Rebuilds when the cart changes (quantity badges) AND
                    // when the selected branch changes (stock/availability,
                    // since BranchController re-scopes kProducts/kPopularProducts).
                    listenable: Listenable.merge([CartController.instance, BranchController.instance]),
                    builder: (context, _) {
                      final popular = _visiblePopularProducts;
                      if (popular.isEmpty) {
                        // First load: shimmering placeholders, not a spinner.
                        if (catalog.isLoading) return const ProductStripSkeleton(height: _stripHeight);
                        return SizedBox(
                          height: 220,
                          child: DataStateView(
                            compact: true,
                            isLoading: false,
                            error: catalog.error,
                            isEmpty: true,
                            onRetry: _retryCatalog,
                            errorScope: ErrorScope.catalog,
                            emptyIcon: Icons.inventory_2_outlined,
                            emptyTitle: _selectedCategoryId == null
                                ? 'No products available yet.'
                                : 'No products in this category yet.',
                            builder: (_) => const SizedBox.shrink(),
                          ),
                        );
                      }
                      return _productStrip(popular);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // Rewards teaser
            FadeSlideIn(
              delay: next(),
              child: _pad(_rewardsCard(context, store.pointsBalance)),
            ),
          ],
        ),
      ),
    );
  }
}
