import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/products_repository.dart';
import '../../../data/repositories/staff_repository.dart';

/// Full Product Management catalog list — search, category filter chips,
/// and a management-focused product card (SKU, margin, edit/pricing
/// shortcuts) rather than the customer-facing storefront card.
class ProductListScreen extends StatefulWidget {
  const ProductListScreen({super.key});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  String? _selectedCategory;
  final _searchController = TextEditingController();

  // Inactive products are not part of the shared catalog, so they are read
  // separately and only when the "Inactive" chip is selected.
  bool _showInactive = false;
  bool _inactiveLoading = false;
  Object? _inactiveError;
  List<InactiveProduct> _inactive = const [];
  final Set<String> _reactivating = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInactive() async {
    setState(() {
      _inactiveLoading = true;
      _inactiveError = null;
    });
    try {
      final rows = await StaffRepository.instance.listInactiveProducts();
      if (!mounted) return;
      setState(() {
        _inactive = rows;
        _inactiveLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inactiveError = e;
        _inactiveLoading = false;
      });
    }
  }

  Future<void> _reactivate(InactiveProduct product) async {
    if (_reactivating.contains(product.id)) return;
    setState(() => _reactivating.add(product.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await StaffRepository.instance.setProductActive(product.id, true);
      // Bring it back into the shared catalog, then refresh this list.
      await ProductsRepository.instance.loadCatalog();
      final rows = await StaffRepository.instance.listInactiveProducts();
      if (!mounted) return;
      setState(() {
        _inactive = rows;
        _reactivating.remove(product.id);
      });
      messenger.showSnackBar(SnackBar(content: Text('"${product.name}" is active again.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _reactivating.remove(product.id));
      messenger.showSnackBar(SnackBar(
        content: Text(e is AppError ? e.message : 'Could not reactivate the product. Please try again.'),
      ));
    }
  }

  List<InactiveProduct> get _filteredInactive {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _inactive;
    return _inactive
        .where((p) => p.name.toLowerCase().contains(query) || (p.sku ?? '').toLowerCase().contains(query))
        .toList();
  }

  Widget _inactiveBody() {
    final items = _filteredInactive;
    return DataStateView(
      isLoading: _inactiveLoading,
      error: _inactiveError,
      isEmpty: items.isEmpty,
      onRetry: _loadInactive,
      emptyIcon: Icons.inventory_2_outlined,
      emptyTitle: 'No inactive products.',
      emptyMessage: 'Products you switch off will appear here so you can reactivate them.',
      builder: (context) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final p = items[i];
          final busy = _reactivating.contains(p.id);
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: AppTextStyles.labelLg, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        '${(p.sku ?? '').isEmpty ? 'No SKU' : p.sku!} • ₱${p.price.toStringAsFixed(2)}',
                        style: AppTextStyles.bodySm,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: busy ? null : () => _reactivate(p),
                  child: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Reactivate'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Product> get _filtered {
    var list = _selectedCategory == null ? kProducts : productsByCategory(_selectedCategory!);
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((p) => p.name.toLowerCase().contains(query) || p.sku.toLowerCase().contains(query)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final products = _filtered;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Product Catalog',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.productAdd),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Search by product name or SKU...',
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('All (${kProducts.length})'),
                      selected: _selectedCategory == null && !_showInactive,
                      onSelected: (_) => setState(() {
                        _selectedCategory = null;
                        _showInactive = false;
                      }),
                    ),
                  ),
                  for (final cat in kProductCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${cat.name} (${productsByCategory(cat.id).length})'),
                        selected: _selectedCategory == cat.id && !_showInactive,
                        onSelected: (_) => setState(() {
                          _selectedCategory = cat.id;
                          _showInactive = false;
                        }),
                      ),
                    ),
                  ChoiceChip(
                    label: const Text('Inactive'),
                    selected: _showInactive,
                    onSelected: (_) {
                      setState(() {
                        _showInactive = true;
                        _selectedCategory = null;
                      });
                      _loadInactive();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: _showInactive
                  ? _inactiveBody()
                  : ListView.separated(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                itemCount: products.length,
                separatorBuilder: (context, index) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final product = products[i];
                  return _ManagedProductCard(
                    product: product,
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.productDetails, arguments: product.id),
                    onEdit: () => Navigator.of(context).pushNamed(AppRoutes.productEdit, arguments: product.id),
                    onPricing: () => Navigator.of(context).pushNamed(AppRoutes.productPricing, arguments: product.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManagedProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onPricing;

  const _ManagedProductCard({
    required this.product,
    required this.onTap,
    required this.onEdit,
    required this.onPricing,
  });

  /// Lowest–highest variant price; falls back to the product price for a
  /// product with no variants (reducing an empty list would throw).
  static String _priceRange(Product product) {
    if (product.variants.isEmpty) return '₱${product.price.toStringAsFixed(0)}';
    final prices = product.variants.map((v) => v.price);
    final lo = prices.reduce((a, b) => a < b ? a : b);
    final hi = prices.reduce((a, b) => a > b ? a : b);
    return '₱${lo.toStringAsFixed(0)}–₱${hi.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
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
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: Icon(product.icon, color: product.color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(product.name, style: AppTextStyles.labelLg, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: product.isActive ? AppColors.successBg : AppColors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              product.isActive ? 'Active' : 'Inactive',
                              style: AppTextStyles.labelSm.copyWith(color: product.isActive ? AppColors.success : AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                      Text('${product.sku} • ${product.variants.length} variant${product.variants.length == 1 ? '' : 's'}', style: AppTextStyles.bodySm),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _priceRange(product),
                  style: AppTextStyles.titleMd.copyWith(color: AppColors.primary),
                ),
                Text('Margin ${product.marginPercent.toStringAsFixed(0)}%', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onPricing,
                    icon: const Icon(Icons.sell_outlined, size: 16),
                    label: const Text('Pricing'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
