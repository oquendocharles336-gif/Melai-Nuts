import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../catalog_store.dart';
import '../models/product.dart';
import '../models/promotion.dart';

/// Loads the public product catalog (categories, products, variants, and
/// per-branch stock) from Supabase and keeps [kProducts]/[kProductCategories]
/// in sync — every existing customer/owner/staff screen that already reads
/// those globals picks the real data up automatically, with no further
/// changes needed on their end.
///
/// It is also a [ChangeNotifier] that reports the *real* load status of the
/// catalog ([isLoading], [error], [hasLoaded]) so screens can show a loading
/// spinner, an error with a retry button, or a genuine empty state instead of
/// treating "not loaded yet" and "failed to load" as "no products".
class ProductsRepository extends ChangeNotifier {
  ProductsRepository._();
  static final ProductsRepository instance = ProductsRepository._();

  Future<void>? _inFlight;
  String? _inFlightBranchId;

  bool _isLoading = false;

  /// True while a catalog fetch is running.
  bool get isLoading => _isLoading;

  AppError? _error;

  /// The customer-safe error from the most recent failed fetch, or null if the
  /// last fetch succeeded (or none has finished yet).
  AppError? get error => _error;

  bool _hasLoaded = false;

  /// True once at least one fetch has succeeded. Distinguishes "not loaded
  /// yet / failed" from "loaded and genuinely empty".
  bool get hasLoaded => _hasLoaded;

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Fetches categories + products + variants + stock and replaces the
  /// contents of [kProductCategories]/[kProducts] in place.
  ///
  /// When [branchId] is given, stock and branch-availability are scoped to
  /// that one branch's `branch_inventory` rows — this is what
  /// [BranchController.selectBranch] calls so switching branches updates
  /// real product availability/stock everywhere `kProducts` is read. With
  /// no [branchId] (the app-boot default, before any branch is chosen),
  /// stock is aggregated across every active branch, as before.
  ///
  /// Never throws: the outcome is reported through [isLoading], [error] and
  /// [hasLoaded]. On failure the last successfully loaded catalog is kept in
  /// place (so a flaky connection never blanks a screen that already has
  /// data) and [error] is set so the UI can offer a retry.
  ///
  /// Concurrent calls for the same branch share one request. A call for a
  /// *different* branch waits for the running request and then runs its own,
  /// so a branch switch is never silently dropped.
  Future<void> loadCatalog({String? branchId}) {
    final running = _inFlight;
    if (running != null) {
      if (_inFlightBranchId == branchId) return running;
      return running.then((_) => loadCatalog(branchId: branchId));
    }
    final future = _runLoad(branchId);
    _inFlight = future;
    _inFlightBranchId = branchId;
    return future;
  }

  Future<void> _runLoad(String? branchId) async {
    _isLoading = true;
    // Deferred: callers such as `initState` may invoke this while the widget
    // tree is building, and notifying listeners synchronously there would
    // trigger "setState() called during build".
    scheduleMicrotask(notifyListeners);
    try {
      await AppErrors.guard(
        () => _fetchAndStoreCatalog(branchId),
        scope: ErrorScope.catalog,
        timeout: AppErrors.rpcTimeout,
      );
      _error = null;
      _hasLoaded = true;
    } catch (e) {
      // Keep whatever catalog was last loaded; report the failure instead.
      _error = AppErrors.from(e, scope: ErrorScope.catalog);
    } finally {
      _isLoading = false;
      _inFlight = null;
      _inFlightBranchId = null;
      notifyListeners();
    }
  }

  Future<void> _fetchAndStoreCatalog(String? branchId) async {
    final categoriesRaw = await _client
        .from('product_categories')
        .select()
        .eq('is_active', true)
        .order('sort_order');

    final branchesRaw = await _client
        .from('branches')
        .select()
        .eq('is_active', true);

    final productsRaw = await _client
        .from('products')
        .select()
        .eq('is_active', true)
        .order('name');

    final salesCounts = await _loadSalesCounts();

    final products = await _hydrateProducts(
      List<Map<String, dynamic>>.from(productsRaw),
      branchId: branchId,
      branchesRaw: List<Map<String, dynamic>>.from(branchesRaw),
      salesCounts: salesCounts,
    );

    final categoryCounts = <String, int>{};
    for (final product in products) {
      if (product.categoryId.isNotEmpty) {
        categoryCounts[product.categoryId] =
            (categoryCounts[product.categoryId] ?? 0) + 1;
      }
    }

    final categories = List<Map<String, dynamic>>.from(categoriesRaw)
        .map((row) => <String, dynamic>{
              ...row,
              'product_count': categoryCounts[row['id'] as String] ?? 0,
            })
        .map(ProductCategory.fromRow)
        .where((category) => category.isActive)
        .toList();

    kProductCategories
      ..clear()
      ..addAll(categories);
    kProducts
      ..clear()
      ..addAll(products);

    await Future.wait([
      _loadPromotions(),
      _loadPopularProducts(),
    ]);
  }

  /// Fetches active categories and their current active-product counts
  /// directly from Supabase. The returned categories are also copied into
  /// the shared catalog cache so existing screens remain compatible.
  Future<List<ProductCategory>> fetchActiveCategoriesWithCounts() async {
    final categoriesRaw = await _client
        .from('product_categories')
        .select()
        .eq('is_active', true)
        .order('sort_order');

    final productsRaw = await _client
        .from('products')
        .select('id,category_id')
        .eq('is_active', true);

    final counts = <String, int>{};
    for (final row in List<Map<String, dynamic>>.from(productsRaw)) {
      final categoryId = row['category_id'] as String?;
      if (categoryId != null && categoryId.isNotEmpty) {
        counts[categoryId] = (counts[categoryId] ?? 0) + 1;
      }
    }

    final categories = List<Map<String, dynamic>>.from(categoriesRaw)
        .map((row) => <String, dynamic>{
              ...row,
              'product_count': counts[row['id'] as String] ?? 0,
            })
        .map(ProductCategory.fromRow)
        .toList();

    kProductCategories
      ..clear()
      ..addAll(categories);
    return categories;
  }

  /// Searches active products in Supabase using the database search function.
  ///
  /// Search is performed against product name, category name, product SKU,
  /// variant SKU, and partial tag text. Optional category IDs and price
  /// bounds are also applied server-side.
  Future<List<Product>> searchProducts({
    required String query,
    Set<String> categoryIds = const {},
    double? minPrice,
    double? maxPrice,
    String? branchId,
  }) async {
    final q = query.trim();
    final params = <String, dynamic>{
      'p_query': q,
      'p_category_ids':
          categoryIds.isEmpty ? null : categoryIds.toList(growable: false),
      'p_min_price': minPrice,
      'p_max_price': maxPrice,
      'p_limit': 100,
    };

    final raw = await _client.rpc('search_customer_products', params: params);
    final rows = List<Map<String, dynamic>>.from(raw as List);

    if (rows.isEmpty) return const [];

    final branchesRaw = await _client
        .from('branches')
        .select()
        .eq('is_active', true);

    final products = await _hydrateProducts(
      rows,
      branchId: branchId,
      branchesRaw: List<Map<String, dynamic>>.from(branchesRaw),
    );

    return products;
  }

  /// Loads one category's current active products straight from Supabase.
  Future<List<Product>> fetchProductsByCategory(
    String categoryId, {
    String? branchId,
  }) async {
    final raw = await _client
        .from('products')
        .select()
        .eq('is_active', true)
        .eq('category_id', categoryId)
        .order('name');

    if (raw.isEmpty) return const [];

    final branchesRaw = await _client
        .from('branches')
        .select()
        .eq('is_active', true);

    return _hydrateProducts(
      List<Map<String, dynamic>>.from(raw),
      branchId: branchId,
      branchesRaw: List<Map<String, dynamic>>.from(branchesRaw),
    );
  }

  Future<List<Product>> _hydrateProducts(
    List<Map<String, dynamic>> productRows, {
    String? branchId,
    required List<Map<String, dynamic>> branchesRaw,
    Map<String, int> salesCounts = const {},
  }) async {
    if (productRows.isEmpty) return const [];

    final ids = productRows.map((row) => row['id'] as String).toList();

    final variantsRaw = await _client
        .from('product_variants')
        .select()
        .inFilter('product_id', ids)
        .order('sort_order');

    final inventoryQuery = _client.from('branch_inventory').select();
    final inventoryRaw = branchId == null
        ? await inventoryQuery.inFilter('product_id', ids)
        : await inventoryQuery
            .eq('branch_id', branchId)
            .inFilter('product_id', ids);

    final branchNameById = <String, String>{
      for (final b in branchesRaw)
        b['id'] as String: b['name'] as String,
    };

    final variantsByProduct = <String, List<Map<String, dynamic>>>{};
    for (final variant in List<Map<String, dynamic>>.from(variantsRaw)) {
      variantsByProduct
          .putIfAbsent(variant['product_id'] as String, () => [])
          .add(variant);
    }

    final stockByVariant = <String, int>{};
    final stockByProduct = <String, int>{};
    final branchesByProduct = <String, Set<String>>{};

    for (final inventory in List<Map<String, dynamic>>.from(inventoryRaw)) {
      final variantId = inventory['variant_id'] as String?;
      final productId = inventory['product_id'] as String;
      final quantity = (inventory['quantity'] as num).toInt();

      if (variantId != null) {
        stockByVariant[variantId] =
            (stockByVariant[variantId] ?? 0) + quantity;
      }
      stockByProduct[productId] =
          (stockByProduct[productId] ?? 0) + quantity;

      if (quantity > 0) {
        final branchName = branchNameById[inventory['branch_id'] as String];
        if (branchName != null) {
          branchesByProduct.putIfAbsent(productId, () => {}).add(branchName);
        }
      }
    }

    return productRows.map((row) {
      final id = row['id'] as String;
      return Product.fromRow(
        row,
        variantRows: variantsByProduct[id] ?? const [],
        stockByVariantId: stockByVariant,
        branchAvailability:
            (branchesByProduct[id] ?? const <String>{}).toList()..sort(),
        totalStock: stockByProduct[id] ?? 0,
        unitsSoldLast30Days: salesCounts[id] ?? 0,
      );
    }).toList();
  }

  /// Real trailing-30-day units-sold count per active product, from
  /// `get_product_sales_30d` — drives `Product.unitsSoldLast30Days` (and in
  /// turn `monthlyRevenue`/margin) on the Product Performance / Pricing Hub
  /// screens. On any failure this returns an empty map, so products just
  /// show 0 units/₱0 revenue rather than a fabricated figure.
  Future<Map<String, int>> _loadSalesCounts() async {
    try {
      final raw = await _client.rpc('get_product_sales_30d');
      final rows = List<Map<String, dynamic>>.from(raw as List);
      return {
        for (final row in rows)
          row['product_id'] as String: (row['units_sold'] as num).toInt(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Fetches active, in-date-window promo banners for the Home dashboard.
  /// Never fabricates a banner: on any failure [kPromotions] is just left
  /// empty (or whatever was last loaded), which the Home screen treats as
  /// "no promo section right now".
  Future<void> _loadPromotions() async {
    try {
      final raw = await _client
          .from('promotions')
          .select()
          .eq('is_active', true)
          .order('sort_order');
      final now = DateTime.now();
      final promotions = List<Map<String, dynamic>>.from(raw).where((row) {
        final startsAt = row['starts_at'] as String?;
        final endsAt = row['ends_at'] as String?;
        if (startsAt != null && DateTime.parse(startsAt).isAfter(now)) return false;
        if (endsAt != null && DateTime.parse(endsAt).isBefore(now)) return false;
        return true;
      }).map(Promotion.fromRow).toList();
      kPromotions
        ..clear()
        ..addAll(promotions);
    } catch (_) {
      // Leave kPromotions as-is; Home hides the section when it's empty.
    }
  }

  /// Ranks the just-loaded [kProducts] by real units sold via the
  /// `get_popular_products` RPC. An empty result stays empty; the app never
  /// invents a popularity ranking when there is no sales data yet.
  Future<void> _loadPopularProducts() async {
    List<Product> ranked = const [];
    try {
      final raw = await _client.rpc('get_popular_products', params: {'p_limit': 8});
      final rows = List<Map<String, dynamic>>.from(raw as List);
      final byId = {for (final p in kProducts) p.id: p};
      ranked = rows
          .map((r) => byId[r['product_id'] as String])
          .whereType<Product>()
          .toList();
    } catch (_) {
      // RPC unavailable/offline — keep the ranking empty instead of inventing it.
    }

    kPopularProducts
      ..clear()
      ..addAll(ranked);
  }

  /// Public list of active branches (for the branch picker on Cart/Checkout).
  Future<List<String>> fetchBranchNames() async {
    try {
      final raw = await _client.from('branches').select('name').eq('is_active', true).order('name');
      return List<Map<String, dynamic>>.from(raw).map((r) => r['name'] as String).toList();
    } catch (_) {
      return const [];
    }
  }

  /// The real lowest and highest selling price in the active catalog
  /// (product base prices and variant prices), used to size the search
  /// price-range slider. Returns `null` when the catalog is empty or the
  /// lookup fails, so the UI can hide the slider rather than invent bounds.
  Future<({double min, double max})?> fetchPriceBounds() async {
    try {
      Future<double?> edge(String table, {required bool ascending}) async {
        final rows = await _client
            .from(table)
            .select('price')
            .order('price', ascending: ascending)
            .limit(1);
        if (rows.isEmpty) return null;
        return (rows.first['price'] as num).toDouble();
      }

      final lows = [
        await edge('products', ascending: true),
        await edge('product_variants', ascending: true),
      ].whereType<double>();
      final highs = [
        await edge('products', ascending: false),
        await edge('product_variants', ascending: false),
      ].whereType<double>();
      if (lows.isEmpty || highs.isEmpty) return null;
      final low = lows.reduce((a, b) => a < b ? a : b);
      final high = highs.reduce((a, b) => a > b ? a : b);
      return (min: low, max: high);
    } catch (_) {
      return null;
    }
  }

  /// Re-checks *right now* how many units of one product/variant are on the
  /// shelf, straight from `branch_inventory` — never from the [kProducts]
  /// cache, which may be stale (loaded at app-boot or the last branch
  /// switch, and never updated by another customer's purchase in the
  /// meantime). Used by [CartController.addProductWithLiveCheck] so
  /// "available stock" always means "available right now", not "available
  /// when the catalog last loaded".
  ///
  /// When [branchId] is given, only that branch's stock counts (matching
  /// what the customer actually sees once they've picked a branch). With no
  /// branch chosen yet, stock is summed across every branch that carries
  /// this variant, same as the aggregate view [loadCatalog] shows at boot.
  ///
  /// Returns `null` (not zero) when the check itself fails — e.g. offline —
  /// so the caller can fall back to the last-known cached stock instead of
  /// wrongly reporting "0 available" during a network hiccup.
  Future<int?> fetchLiveStock({
    required String productId,
    required String variantId,
    String? branchId,
  }) async {
    if (variantId.isEmpty) return null;
    try {
      var query = _client
          .from('branch_inventory')
          .select('quantity')
          .eq('product_id', productId)
          .eq('variant_id', variantId);
      if (branchId != null) {
        query = query.eq('branch_id', branchId);
      }
      final raw = await query;
      final rows = List<Map<String, dynamic>>.from(raw);
      return rows.fold<int>(0, (sum, r) => sum + (r['quantity'] as int));
    } catch (_) {
      return null;
    }
  }

  /// Real, staff-configured promotions that specifically call out this
  /// product (`promotions.product_id`) or its category
  /// (`promotions.category_id`) — shown on the Product Details screen's
  /// "Applicable Promotions" section. Only currently-active, in-date-window
  /// rows are returned; on any failure (or when none apply) this returns an
  /// empty list rather than a fabricated offer.
  Future<List<Promotion>> fetchApplicablePromotions({
    required String productId,
    required String categoryId,
  }) async {
    try {
      final filter = categoryId.isEmpty
          ? 'product_id.eq.$productId'
          : 'product_id.eq.$productId,category_id.eq.$categoryId';
      final raw = await _client
          .from('promotions')
          .select()
          .eq('is_active', true)
          .or(filter)
          .order('sort_order');
      final now = DateTime.now();
      return List<Map<String, dynamic>>.from(raw).where((row) {
        final startsAt = row['starts_at'] as String?;
        final endsAt = row['ends_at'] as String?;
        if (startsAt != null && DateTime.parse(startsAt).isAfter(now)) return false;
        if (endsAt != null && DateTime.parse(endsAt).isBefore(now)) return false;
        return true;
      }).map(Promotion.fromRow).toList();
    } catch (_) {
      return const [];
    }
  }
}
