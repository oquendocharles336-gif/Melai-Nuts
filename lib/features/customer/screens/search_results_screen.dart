import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/products_repository.dart';
import '../cart_controller.dart';
import '../widgets/product_card.dart';
import 'cart_screen.dart';
import 'product_details_screen.dart';

/// Customer product search backed by Supabase.
///
/// Queries are executed against the real `products`, `product_categories`,
/// `product_variants`, and `branch_inventory` data through
/// [ProductsRepository.searchProducts]. No prototype/dummy catalog is used.
class SearchResultsScreen extends StatefulWidget {
  final String query;

  const SearchResultsScreen({super.key, this.query = ''});

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);

  final Set<String> _selectedCategories = {};
  // null = no price filter. The customer must choose a range; we never
  // apply one silently. Bounds come from the real catalog prices.
  RangeValues? _priceRange;
  RangeValues? _priceBounds;

  Timer? _searchDebounce;
  int _requestVersion = 0;
  bool _loading = true;
  String? _error;
  List<Product> _results = const [];
  List<ProductCategory> _categories = const [];

  @override
  void initState() {
    super.initState();
    _loadCategoriesAndSearch();
  }

  Future<void> _loadCategoriesAndSearch() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final categories =
          await ProductsRepository.instance.fetchActiveCategoriesWithCounts();
      if (!mounted) return;
      final bounds = await ProductsRepository.instance.fetchPriceBounds();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _priceBounds = (bounds == null || bounds.min >= bounds.max)
            ? null
            : RangeValues(bounds.min.floorToDouble(), bounds.max.ceilToDouble());
      });
      await _runSearch();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'We could not load the product catalog. Please try again.';
      });
    }
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), _runSearch);
  }

  Future<void> _runSearch() async {
    final request = ++_requestVersion;
    final query = _controller.text.trim();

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await ProductsRepository.instance.searchProducts(
        query: query,
        categoryIds: _selectedCategories,
        minPrice: _priceRange?.start,
        maxPrice: _priceRange?.end,
        branchId: BranchController.instance.selectedBranch?.id,
      );

      if (!mounted || request != _requestVersion) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _loading = false;
        _error = 'We could not search products right now. Please try again.';
      });
    }
  }

  Future<void> _openFilters() async {
    final categories = _categories;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        var temporaryCategories = <String>{..._selectedCategories};
        final bounds = _priceBounds;
        RangeValues? temporaryPriceRange = _priceRange;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: DraggableScrollableSheet(
                initialChildSize: 0.75,
                minChildSize: 0.5,
                maxChildSize: 0.95,
                expand: false,
                builder: (context, scrollController) {
                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Filter & Refine',
                              style: AppTextStyles.headlineSm),
                          TextButton(
                            onPressed: () => setSheetState(() {
                              temporaryCategories.clear();
                              temporaryPriceRange = null;
                            }),
                            child: const Text('Reset All'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('Product Category',
                          style: AppTextStyles.titleMd),
                      const SizedBox(height: 8),
                      for (final category in categories)
                        CheckboxListTile(
                          value: temporaryCategories.contains(category.id),
                          title: Text(category.name),
                          secondary: Text('(${category.productCount})'),
                          activeColor: AppColors.primary,
                          onChanged: (selected) => setSheetState(() {
                            if (selected == true) {
                              temporaryCategories.add(category.id);
                            } else {
                              temporaryCategories.remove(category.id);
                            }
                          }),
                        ),
                      const SizedBox(height: 10),
                      if (bounds != null) ...[
                        Text('Price Range', style: AppTextStyles.titleMd),
                        RangeSlider(
                          values: temporaryPriceRange ?? bounds,
                          min: bounds.start,
                          max: bounds.end,
                          activeColor: AppColors.primary,
                          labels: RangeLabels(
                            '₱${(temporaryPriceRange ?? bounds).start.toStringAsFixed(0)}',
                            '₱${(temporaryPriceRange ?? bounds).end.toStringAsFixed(0)}',
                          ),
                          onChanged: (value) => setSheetState(
                            () => temporaryPriceRange = value,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      PrimaryButton(
                        label: 'Apply Filters',
                        onPressed: () {
                          setState(() {
                            _selectedCategories
                              ..clear()
                              ..addAll(temporaryCategories);
                            // A range spanning the whole catalog is no filter.
                            _priceRange = (bounds != null &&
                                    temporaryPriceRange != null &&
                                    temporaryPriceRange!.start <= bounds.start &&
                                    temporaryPriceRange!.end >= bounds.end)
                                ? null
                                : temporaryPriceRange;
                          });
                          Navigator.of(context).pop();
                          _runSearch();
                        },
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: widget.query.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (_) => _scheduleSearch(),
          onSubmitted: (_) => _runSearch(),
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'Search Melai Nuts products...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: cart,
          builder: (context, _) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _loading ? 'Searching…' : '${_results.length} results found',
                        style: AppTextStyles.bodyMd,
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading && _categories.isEmpty
                            ? null
                            : _openFilters,
                        icon: const Icon(Icons.tune_rounded, size: 16),
                        label: Text(
                          _selectedCategories.isEmpty
                              ? 'Filters'
                              : 'Filters (${_selectedCategories.length})',
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _buildResults(),
                ),
                ListenableBuilder(
                  listenable: cart,
                  builder: (context, _) {
                    if (cart.itemCount == 0) return const SizedBox.shrink();
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, -4),
                          ),
                        ],
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: PrimaryButton(
                            label: 'View Cart (${cart.itemCount})',
                            icon: Icons.shopping_bag_outlined,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const CartScreen(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadCategoriesAndSearch,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      final query = _controller.text.trim();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_rounded, size: 48),
              const SizedBox(height: 12),
              Text(
                query.isEmpty
                    ? 'No products are currently available.'
                    : 'No products match “$query”.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              if (_selectedCategories.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Try removing a category or price filter.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodySm,
                ),
              ],
            ],
          ),
        ),
      );
    }

    final cart = CartController.instance;

    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: _results.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.68,
      ),
      itemBuilder: (context, i) {
        final product = _results[i];
        if (product.variants.isEmpty) {
          return ProductCard(
            product: product,
            quantityInCart: 0,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ProductDetailsScreen(product: product),
              ),
            ),
            onAdd: () {},
          );
        }

        final defaultVariant = product.variants.first;
        return ProductCard(
          product: product,
          quantityInCart:
              cart.quantityFor(product.id, defaultVariant.label),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProductDetailsScreen(product: product),
            ),
          ),
          onAdd: () =>
              addToCartWithFeedback(context, product, defaultVariant),
        );
      },
    );
  }
}
