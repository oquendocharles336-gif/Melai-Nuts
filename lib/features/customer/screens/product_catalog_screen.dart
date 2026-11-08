import 'package:flutter/material.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/list_tools.dart';
import '../../../core/widgets/motion.dart';
import '../../../core/widgets/page_transitions.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/repositories/products_repository.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../cart_controller.dart';
import '../widgets/category_chip.dart';
import '../widgets/product_card.dart';
import '../widgets/storefront_widgets.dart';
import 'cart_screen.dart';
import 'product_details_screen.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Main "Catalog" tab: search box, category chips, sort row and the full
/// product grid (matches the prototype's Product Catalog screen).
class ProductCatalogScreen extends StatefulWidget {
  const ProductCatalogScreen({super.key});

  @override
  State<ProductCatalogScreen> createState() => _ProductCatalogScreenState();
}

class _ProductCatalogScreenState extends State<ProductCatalogScreen> {
  String? _selectedCategory; // null = "All"
  String _sortLabel = 'Bestsellers';
  String _query = '';

  /// Bumped to rebuild the search box empty when "Clear search" is tapped.
  int _searchBoxKey = 0;

  List<Product> get _filtered {
    final inCategory = _selectedCategory == null ? kProducts : productsByCategory(_selectedCategory!);
    if (_query.trim().isEmpty) return inCategory;
    return inCategory.where((p) => productMatchesSearch(p, _query)).toList();
  }

  void _openProduct(Product product) {
    Navigator.of(context).push(
      FadeSlideRoute(builder: (_) => ProductDetailsScreen(product: product)),
    );
  }

  void _clearSearch() => setState(() {
        _query = '';
        _selectedCategory = null;
        _searchBoxKey++;
      });

  void _pickSort() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in [
              'Bestsellers',
              'Price: Low to High',
              'Price: High to Low',
              // Only offered once real customer reviews exist; until then
              // every rating is 0 and this sort would be meaningless.
              if (kProducts.any((p) => p.reviewCount > 0)) 'Highest Rated',
            ])
              ListTile(
                title: Text(option),
                trailing: _sortLabel == option
                    ? const Icon(Icons.check, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (choice != null) setState(() => _sortLabel = choice);
  }

  @override
  void initState() {
    super.initState();
    // Catalog is preloaded at app boot; retry here if that hasn't succeeded.
    final catalog = ProductsRepository.instance;
    if (!catalog.hasLoaded && !catalog.isLoading) _reload();
  }

  Future<void> _reload() => ProductsRepository.instance.loadCatalog(
        branchId: BranchController.instance.selectedBranch?.id,
      );

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole screen (not just the grid) when the catalog load
    // finishes/fails or the branch changes, because the filtered + sorted
    // product list below is computed from the shared catalog in this build.
    return ListenableBuilder(
      listenable: Listenable.merge([
        ProductsRepository.instance,
        BranchController.instance,
      ]),
      builder: (context, _) => LuxeBackground(child: _buildScaffold(context)),
    );
  }

  List<Product> _sorted(List<Product> source) {
    final products = List<Product>.from(source);
    switch (_sortLabel) {
      case 'Price: Low to High':
        products.sort((a, b) => a.price.compareTo(b.price));
        break;
      case 'Price: High to Low':
        products.sort((a, b) => b.price.compareTo(a.price));
        break;
      case 'Highest Rated':
        products.sort((a, b) => b.rating.compareTo(a.rating));
        break;
      default:
        // Bestsellers: real units sold (kPopularProducts, ranked server-side
        // by get_popular_products). Products with no sales keep catalog order.
        final rank = {
          for (var i = 0; i < kPopularProducts.length; i++) kPopularProducts[i].id: i,
        };
        if (rank.isNotEmpty) {
          final original = {for (var i = 0; i < products.length; i++) products[i].id: i};
          products.sort((a, b) {
            final ra = rank[a.id] ?? 1 << 30;
            final rb = rank[b.id] ?? 1 << 30;
            return ra != rb ? ra.compareTo(rb) : original[a.id]!.compareTo(original[b.id]!);
          });
        }
        break;
    }
    return products;
  }

  Widget _buildScaffold(BuildContext context) {
    final cart = CartController.instance;
    final t = AppLocalizations.of(context);
    final products = _sorted(_filtered);
    final searching = _query.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const LuxeAppBar(
        title: 'Product Catalog',
        actions: [CartIconButton(), SizedBox(width: 6)],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
              child: AppSearchBar(
                key: ValueKey('catalog-search-$_searchBoxKey'),
                hint: 'Search garlic, spicy, sweet...',
                debounce: const Duration(milliseconds: 200),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 4),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CategoryChip(
                      label: 'All (${kProducts.length})',
                      selected: _selectedCategory == null,
                      onTap: () => setState(() => _selectedCategory = null),
                    ),
                  ),
                  for (final cat in kProductCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CategoryChip(
                        label: '${cat.name} (${cat.productCount})',
                        selected: _selectedCategory == cat.id,
                        onTap: () => setState(() => _selectedCategory = cat.id),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        searching
                            ? '${products.length} result${products.length == 1 ? '' : 's'} for "${_query.trim()}"'
                            : 'Showing ${products.length} artisanal nut batches',
                        key: ValueKey('${products.length}-$searching'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _pickSort,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.expand_more_rounded, size: 18),
                    label: Text(_sortLabel, style: AppTextStyles.labelLg),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: cart,
                builder: (context, _) {
                  final catalog = ProductsRepository.instance;
                  return DataStateView(
                    isLoading: catalog.isLoading,
                    error: catalog.error,
                    isEmpty: products.isEmpty,
                    onRetry: _reload,
                    errorScope: ErrorScope.catalog,
                    emptyIcon: searching ? Icons.search_off_rounded : Icons.inventory_2_outlined,
                    emptyTitle: searching
                        ? 'No nuts match "${_query.trim()}"'
                        : _selectedCategory == null
                            ? t.noProductsYet
                            : t.noProductsInCategory,
                    emptyMessage: searching ? 'Try another word, or look in every category.' : t.noProductsAtBranch,
                    emptyActionLabel: searching || _selectedCategory != null ? 'Clear search' : null,
                    onEmptyAction: searching || _selectedCategory != null ? _clearSearch : null,
                    loadingMessage: t.loadingProducts,
                    loadingBuilder: (_) => const ProductGridSkeleton(),
                    builder: (context) => RefreshIndicator(
                      onRefresh: _reload,
                      child: GridView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.xs,
                          AppSpacing.md,
                          AppSpacing.md,
                        ),
                        itemCount: products.length,
                        gridDelegate: productGridDelegate,
                        itemBuilder: (context, i) {
                          final product = products[i];
                          // Same empty-variant branch as product_list_screen: a
                          // product with no sizes still shows (and opens its
                          // "Currently unavailable" details page) instead of
                          // throwing on `variants.first`.
                          if (product.variants.isEmpty) {
                            return ProductCard(
                              product: product,
                              quantityInCart: 0,
                              onTap: () => _openProduct(product),
                              onAdd: () {},
                            );
                          }
                          final defaultVariant = product.variants.first;
                          return FadeSlideIn(
                            // Staggered on the first screenful only.
                            delay: Duration(milliseconds: i < 8 ? 40 * i : 0),
                            child: ProductCard(
                              product: product,
                              quantityInCart: cart.quantityFor(product.id, defaultVariant.label),
                              onTap: () => _openProduct(product),
                              onAdd: () => addToCartWithFeedback(context, product, defaultVariant),
                              onDecrease: () => decreaseInCartWithFeedback(context, product, defaultVariant),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
            const _CartSummaryBar(),
          ],
        ),
      ),
    );
  }
}

/// "N Items • ₱total — View Cart", slides up once something is in the cart.
class _CartSummaryBar extends StatelessWidget {
  const _CartSummaryBar();

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        final show = cart.itemCount > 0;
        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: !show
              ? const SizedBox(width: double.infinity)
              : SafeArea(
                  top: false,
                  child: Container(
                    margin: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      boxShadow: AppShadows.md,
                    ),
                    child: Material(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(
                          FadeSlideRoute(builder: (_) => const CartScreen()),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              BumpingCountBadge(
                                count: cart.itemCount,
                                child: const Icon(Icons.shopping_bag_outlined, color: AppColors.onPrimary),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Text(
                                  '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'} • ₱${cart.subtotal.toStringAsFixed(0)}',
                                  style: AppTextStyles.labelLg.copyWith(color: AppColors.onPrimary),
                                ),
                              ),
                              Text('View Cart', style: AppTextStyles.labelLg.copyWith(color: AppColors.onPrimary)),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_forward_rounded, color: AppColors.onPrimary, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
