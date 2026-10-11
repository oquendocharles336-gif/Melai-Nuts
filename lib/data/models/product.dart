import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../repositories/icon_registry.dart';

/// A single purchasable size/packaging option for a [Product]
/// (e.g. "100g Retail Foil" vs "250g Standup Pouch").
class ProductVariant {
  /// The `product_variants.id` this came from. Needed (alongside
  /// [Product.id]) to look up/lock the exact `branch_inventory` row when
  /// re-validating stock on add-to-cart and at checkout. Empty for any
  /// variant that wasn't built from a real row (should not happen in the
  /// live app, but never treated as a match against a real inventory row).
  final String id;
  final String label;
  final double price;
  final String? badge; // e.g. "Most Popular", "Best Value"

  /// Cost of goods (COGS) for this specific variant/pack size, used by the
  /// Product Management "Pricing" screens to compute per-variant margin.
  /// Optional since customer-facing screens don't need it.
  final double? costPrice;

  /// Optional dedicated SKU/barcode for this variant (e.g. "MN-GP-100").
  final String? sku;

  /// Current stock across all branches for this variant, shown on the
  /// Variants management screen. Optional/cosmetic for this frontend-only
  /// build.
  final int? stockOnHand;

  const ProductVariant({
    this.id = '',
    required this.label,
    required this.price,
    this.badge,
    this.costPrice,
    this.sku,
    this.stockOnHand,
  });

  /// Gross margin percentage (0-100) for this variant. Falls back to 0 if
  /// no cost price was supplied.
  double get marginPercent =>
      costPrice == null || price == 0 ? 0 : ((price - costPrice!) / price) * 100;

  double get netProfit => costPrice == null ? 0 : price - costPrice!;

  bool get isOutOfStock => stockOnHand != null && stockOnHand! <= 0;

  /// Builds a variant from a `product_variants` row, optionally folding in
  /// the stock on hand for one branch (summed from `branch_inventory`).
  factory ProductVariant.fromRow(Map<String, dynamic> row, {int? stockOnHand}) {
    return ProductVariant(
      id: row['id'] as String? ?? '',
      label: row['label'] as String,
      price: (row['price'] as num).toDouble(),
      badge: row['badge'] as String?,
      costPrice: (row['cost_price'] as num?)?.toDouble(),
      sku: row['sku'] as String?,
      stockOnHand: stockOnHand,
    );
  }
}

/// A product category (e.g. Garlic Nuts, Sweet Peanuts).
class ProductCategory {
  final String id;
  final String name;
  final IconData icon;
  final Color color;

  /// Whether staff currently want this category shown to customers
  /// (`product_categories.is_active`). The catalog query only ever fetches
  /// active categories in the first place — see
  /// [ProductsRepository.loadCatalog] — so in practice every category that
  /// makes it into [kProductCategories] already has this set to `true`;
  /// the field is kept on the model (rather than assumed) so nothing here
  /// is hardcoded.
  final bool isActive;

  /// Number of active products currently assigned to this category.
  final int productCount;

  /// Real, staff-uploaded category photo (Supabase Storage/CDN URL). Null
  /// until one is uploaded — screens fall back to [icon]/[color] rather
  /// than a fake stock photo.
  final String? imageUrl;

  const ProductCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    this.isActive = true,
    this.productCount = 0,
    this.imageUrl,
  });

  /// Builds a category from a `product_categories` row.
  factory ProductCategory.fromRow(Map<String, dynamic> row) {
    return ProductCategory(
      id: row['id'] as String,
      name: row['label'] as String,
      icon: IconRegistry.icon(row['icon_name'] as String?),
      color: const Color(0xFF8D6E63),
      isActive: (row['is_active'] as bool?) ?? true,
      productCount: (row['product_count'] as num?)?.toInt() ?? 0,
      imageUrl: row['image_url'] as String?,
    );
  }
}

/// Product record used throughout the customer storefront. Values come from Supabase.
///
/// There are no bundled product photos in this frontend-only build, so
/// [icon] + [color] are used to render a consistent, on-brand placeholder
/// image wherever a photo would normally go (see [ProductCard]).
class Product {
  final String id;
  final String name;
  final String variantLabel;
  final String categoryId;
  final double price;
  final double? originalPrice;
  final double rating;
  final int reviewCount;
  final String? badge; // "Best Seller", "Spicy", "Fresh Batch"...
  final String stockLabel;
  final String description;
  final List<String> branchAvailability;
  final List<ProductVariant> variants;
  final List<String> spiceLevels;
  final IconData icon;
  final Color color;

  /// Ordered real photo URLs from Supabase Storage/CDN. Empty means no
  /// photos have been uploaded yet — [ProductCard] and detail screens fall
  /// back to the [icon]/[color] placeholder rather than a fake image.
  final List<String> images;

  // --- Product Management / Pricing Hub fields (Owner & Staff) ---------
  // All optional with sensible defaults so existing customer-facing code
  // (Batch 2) keeps working unchanged.

  /// Master SKU code shown in Product Management screens, e.g. "MN-GP-CORE".
  final String sku;

  /// Cost of goods sold (COGS) for the product's default/base variant, used
  /// to compute gross margin on the Pricing Hub and Add/Edit Product forms.
  final double costPrice;

  /// Whether this product is currently published/active in the catalog and
  /// POS registers. Inactive products are hidden from the storefront.
  final bool isActive;

  /// Free-form highlight tags (e.g. "Laguna Heritage", "Bestseller").
  final List<String> tags;

  /// Units sold across all branches in the trailing 30 days — drives the
  /// Product Performance ranking screen.
  final int unitsSoldLast30Days;

  /// Staff/owner "Featured" toggle (`products.is_featured`). Used as a
  /// fallback for the Home dashboard's "Popular Near You" section when
  /// there isn't yet enough real sales history to rank products by demand.
  final bool isFeatured;

  const Product({
    required this.id,
    required this.name,
    required this.variantLabel,
    required this.categoryId,
    required this.price,
    this.originalPrice,
    required this.rating,
    required this.reviewCount,
    this.badge,
    required this.stockLabel,
    required this.description,
    required this.branchAvailability,
    required this.variants,
    this.spiceLevels = const [],
    required this.icon,
    required this.color,
    this.images = const [],
    this.sku = '',
    this.costPrice = 0,
    this.isActive = true,
    this.tags = const [],
    this.unitsSoldLast30Days = 0,
    this.isFeatured = false,
  });

  /// True only when real computed stock is actually zero — never a
  /// fabricated guess. Drives whether [ProductCard] lets the customer add
  /// this product to their cart.
  bool get isOutOfStock => stockLabel == 'Out of Stock';
  bool get isLowStock => stockLabel == 'Low Stock';

  /// Foreground/background colors for [stockLabel], shared by every screen
  /// that shows it (Home, Catalog, Product Details) so "Out of Stock" is
  /// never rendered as if it were a success state.
  Color get stockLabelColor =>
      isOutOfStock ? AppColors.error : (isLowStock ? AppColors.warning : AppColors.success);
  Color get stockLabelBg =>
      isOutOfStock ? AppColors.errorBg : (isLowStock ? AppColors.warningBg : AppColors.successBg);

  /// Gross margin percentage (0-100) on the base price vs [costPrice].
  double get marginPercent =>
      costPrice <= 0 || price == 0 ? 0 : ((price - costPrice) / price) * 100;

  double get netProfitPerUnit => price - costPrice;

  double get monthlyRevenue => price * unitsSoldLast30Days;

  /// Builds a product from a `products` row plus its already-fetched
  /// `product_variants` rows and per-branch stock. There is no review system
  /// backing this app yet, so rating/reviewCount stay at 0 (honestly "no
  /// reviews yet") rather than a made-up number.
  factory Product.fromRow(
    Map<String, dynamic> row, {
    required List<Map<String, dynamic>> variantRows,
    required Map<String, int> stockByVariantId,
    required List<String> branchAvailability,
    required int totalStock,
    int unitsSoldLast30Days = 0,
  }) {
    final variants = variantRows
        .map((v) => ProductVariant.fromRow(v, stockOnHand: stockByVariantId[v['id']]))
        .toList();
    return Product(
      id: row['id'] as String,
      name: row['name'] as String,
      variantLabel: variants.isNotEmpty ? variants.first.label : '',
      categoryId: (row['category_id'] as String?) ?? '',
      price: (row['price'] as num).toDouble(),
      originalPrice: (row['original_price'] as num?)?.toDouble(),
      rating: 0,
      reviewCount: 0,
      stockLabel: totalStock <= 0
          ? 'Out of Stock'
          : (totalStock <= 10 ? 'Low Stock' : 'In Stock'),
      description: (row['description'] as String?) ?? '',
      branchAvailability: branchAvailability,
      variants: variants,
      icon: IconRegistry.icon(row['icon_name'] as String?, fallback: Icons.eco_rounded),
      color: IconRegistry.color(row['color_hex'] as String?),
      images: List<String>.from((row['images'] as List?) ?? const []),
      sku: (row['sku'] as String?) ?? '',
      // COGS is only ever recorded per-variant (`product_variants.cost_price`,
      // set by the "Standard" variant on Add/Edit Product) — there is no
      // `products.cost_price` column — so the product-level cost shown on
      // the Pricing Hub/Performance screens is the first variant's cost.
      costPrice: variants.isNotEmpty ? (variants.first.costPrice ?? 0) : 0,
      isActive: (row['is_active'] as bool?) ?? true,
      tags: List<String>.from((row['tags'] as List?) ?? const []),
      // Real trailing-30-day unit count from `get_product_sales_30d` (see
      // ProductsRepository._loadSalesCounts), never a placeholder — this
      // drives monthlyRevenue/marginPercent on the Performance screens.
      unitsSoldLast30Days: unitsSoldLast30Days,
      isFeatured: (row['is_featured'] as bool?) ?? false,
    );
  }
}
