import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/products_repository.dart';
import '../cart_controller.dart';
import '../widgets/product_card.dart';
import 'product_details_screen.dart';

/// Customer product listing for one live Supabase category.
class ProductListScreen extends StatefulWidget {
  final String categoryId;

  const ProductListScreen({super.key, required this.categoryId});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  late Future<List<Product>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Product>> _load() {
    return ProductsRepository.instance.fetchProductsByCategory(
      widget.categoryId,
      branchId: BranchController.instance.selectedBranch?.id,
    );
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: _categoryName(widget.categoryId),
        showBack: true,
      ),
      body: SafeArea(
        child: FutureBuilder<List<Product>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        'We could not load products for this category.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodyMd,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ),
                ),
              );
            }

            final products = snapshot.data ?? const <Product>[];
            if (products.isEmpty) {
              return Center(
                child: Text(
                  'No active products are available in this category.',
                  style: AppTextStyles.bodyMd,
                ),
              );
            }

            return ListenableBuilder(
              listenable: cart,
              builder: (context, _) {
                return ListView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: products.length,
                  itemBuilder: (context, i) {
                    final product = products[i];
                    if (product.variants.isEmpty) {
                      return ProductCard(
                        product: product,
                        quantityInCart: 0,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ProductDetailsScreen(product: product),
                          ),
                        ),
                        onAdd: () {},
                      );
                    }

                    final variant = product.variants.first;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ProductCard(
                        product: product,
                        quantityInCart:
                            cart.quantityFor(product.id, variant.label),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ProductDetailsScreen(product: product),
                          ),
                        ),
                        onAdd: () =>
                            addToCartWithFeedback(context, product, variant),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _categoryName(String id) {
    final category = findCategoryById(id);
    return category.id.isEmpty ? 'Products' : category.name;
  }
}
