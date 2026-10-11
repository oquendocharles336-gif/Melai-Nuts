import '../../data/models/product.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/staff_repository.dart';

/// The `staff_save_product` payload for an existing variant. Includes the id
/// so the database updates that row instead of creating a new one.
Map<String, dynamic> variantToPayload(ProductVariant v) => {
      if (v.id.isNotEmpty) 'id': v.id,
      'label': v.label,
      'price': v.price,
      'cost_price': v.costPrice,
      'sku': v.sku,
      'badge': v.badge,
    };

/// Saves [variants] as the complete variant list of [product] and reloads the
/// shared catalog so every screen sees the result.
///
/// `staff_save_product` replaces the whole list: variants that are left out
/// are deleted (and refused by the database if they have stock or order
/// history), so callers must pass every variant they want to keep. The
/// product's base price follows its cheapest variant, matching the pricing
/// screen. Throws an [AppError] with a readable message on failure.
Future<void> saveProductVariants(
  Product product,
  List<Map<String, dynamic>> variants,
) async {
  if (variants.isEmpty) {
    throw ArgumentError('A product needs at least one variant.');
  }
  final lowest = variants
      .map((v) => (v['price'] as num).toDouble())
      .reduce((a, b) => a < b ? a : b);
  await StaffRepository.instance.saveProduct(
    productId: product.id,
    name: product.name,
    description: product.description,
    categoryId: product.categoryId.isEmpty ? null : product.categoryId,
    price: lowest,
    sku: product.sku,
    images: product.images,
    isActive: product.isActive,
    isFeatured: product.isFeatured,
    variants: variants,
  );
  await ProductsRepository.instance.loadCatalog();
}
