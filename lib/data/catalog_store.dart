import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import 'models/branch.dart';
import 'models/product.dart';
import 'models/promotion.dart';

/// In-memory cache of the real product catalog, populated exclusively by
/// [ProductsRepository.loadCatalog] from Supabase (`product_categories` /
/// `products` / `product_variants` / `branch_inventory` tables). Nothing in
/// this file is hardcoded or fabricated: both lists start empty and stay
/// empty until a real fetch succeeds, so an empty catalog renders the
/// storefront's existing empty-state UI rather than fake placeholder rows.
List<ProductCategory> kProductCategories = <ProductCategory>[];

/// Real staff-managed promotions loaded from Supabase.
final List<Promotion> kPromotions = <Promotion>[];

/// Real branch list — starts empty until `BranchRepository.loadBranches`
/// resolves. No placeholder branches: a wrong address/phone/hours is
/// actively misleading rather than just incomplete.
final List<Branch> kBranches = <Branch>[];

/// Real product catalog — starts empty until loaded from Supabase.
final List<Product> kProducts = <Product>[];

/// "Popular Near You" ranking for the customer Home dashboard, ranked by
/// real units sold across all branches through the Supabase RPC
/// `get_popular_products`. It stays empty until the backend has real sales
/// data; no fallback products are fabricated.
final List<Product> kPopularProducts = <Product>[];

/// Placeholder shown when a product id can't be found (e.g. it was
/// removed, or no product data has been loaded yet). Never treated as a
/// real record — every field signals "unavailable".
Product _unknownProduct(String id) => Product(
      id: id,
      name: 'Product unavailable',
      variantLabel: '',
      categoryId: '',
      price: 0,
      rating: 0,
      reviewCount: 0,
      stockLabel: 'Unavailable',
      description: 'This product could not be found.',
      branchAvailability: const [],
      variants: const [],
      icon: Icons.help_outline_rounded,
      color: AppColors.textMuted,
    );

/// Returns the product with [id], or a clearly-labeled placeholder if no
/// matching product exists (e.g. catalog not loaded yet).
Product findProductById(String id) {
  return kProducts.firstWhere((p) => p.id == id, orElse: () => _unknownProduct(id));
}

/// Placeholder shown when a category id can't be found (e.g. categories
/// haven't loaded yet, or the category was deleted). Never a real record.
const _unknownCategory = ProductCategory(
  id: '',
  name: 'Uncategorized',
  icon: Icons.help_outline_rounded,
  color: AppColors.textMuted,
);

/// Returns the category with [id], or a clearly-labeled placeholder if no
/// matching category exists.
ProductCategory findCategoryById(String id) {
  return kProductCategories.firstWhere(
    (c) => c.id == id,
    orElse: () => _unknownCategory,
  );
}

List<Product> productsByCategory(String categoryId) {
  return kProducts.where((p) => p.categoryId == categoryId).toList();
}
