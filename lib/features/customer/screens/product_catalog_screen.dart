import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/repositories/products_repository.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../cart_controller.dart';
import '../widgets/category_chip.dart';
import '../widgets/product_card.dart';
import 'cart_screen.dart';
import 'product_details_screen.dart';
import 'search_results_screen.dart';

/// Main "Catalog" tab: category chips + sort row + full product grid
/// (matches the prototype's Product Catalog screen).
class ProductCatalogScreen extends StatefulWidget {
  const ProductCatalogScreen({super.key});

  @override
  State<ProductCatalogScreen> createState() => _ProductCatalogScreenState();
}

class _ProductCatalogScreenState extends State<ProductCatalogScreen> {
  String? _selectedCategory; // null = "All"
  String _sortLabel = 'Bestsellers';

  List<Product> get _filtered {
    if (_selectedCategory == null) return kProducts;
    return productsByCategory(_selectedCategory!);
  }

  void _openProduct(Product product) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProductDetailsScreen(product: product)),
    );
  }

  void _pickSort() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
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
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final cart = CartController.instance;
    var products = List<Product>.from(_filtered);
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

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Product Catalog'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchResultsScreen(query: '')),
            ),
          ),
          ListenableBuilder(
            listenable: cart,
            builder: (context, _) => Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: const Icon(Icons.shopping_bag_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CartScreen()),
                  ),
                ),
                if (cart.itemCount > 0)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${cart.itemCount}',
                        style: const TextStyle(color: Colors.white, fontSize: 9),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
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
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 6,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Showing ${products.length} artisanal nut batches',
                    style: AppTextStyles.bodySm,
                  ),
                  InkWell(
                    onTap: _pickSort,
                    child: Row(
                      children: [
                        Text(_sortLabel, style: AppTextStyles.labelLg),
                        const Icon(Icons.expand_more_rounded, size: 18),
                      ],
                    ),
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
                    emptyIcon: Icons.inventory_2_outlined,
                    emptyTitle: _selectedCategory == null
                        ? 'No products yet.'
                        : 'No products in this category yet.',
                    emptyMessage: 'Check back soon for artisanal nut batches.',
                    loadingMessage: 'Loading products...',
                    builder: (context) => RefreshIndicator(
                      onRefresh: _reload,
                      child: GridView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          0,
                          AppSpacing.md,
                          AppSpacing.md,
                        ),
                        itemCount: products.length,
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.68,
                        ),
                        itemBuilder: (context, i) {
                          final product = products[i];
                          final defaultVariant = product.variants.first;
                          return ProductCard(
                            product: product,
                            quantityInCart: cart.quantityFor(product.id, defaultVariant.label),
                            onTap: () => _openProduct(product),
                            onAdd: () => addToCartWithFeedback(context, product, defaultVariant),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
            ListenableBuilder(
              listenable: cart,
              builder: (context, _) {
                if (cart.itemCount == 0) return const SizedBox.shrink();
                return SafeArea(
                  top: false,
                  child: Container(
                    margin: const EdgeInsets.all(AppSpacing.md),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.darkBrown,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: AppShadows.md,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${cart.itemCount} Items • ₱${cart.subtotal.toStringAsFixed(0)}',
                            style: AppTextStyles.labelLg.copyWith(color: Colors.white),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const CartScreen()),
                          ),
                          icon: const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 20),
                          label: Text(
                            'View Cart',
                            style: AppTextStyles.labelLg.copyWith(color: Colors.white),
                          ),
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.15),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
