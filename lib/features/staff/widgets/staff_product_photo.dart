import 'package:flutter/material.dart';

import '../../../data/catalog_store.dart';
import '../../../data/repositories/products_repository.dart';
import '../../customer/widgets/product_card.dart';

/// The product photo on staff screens (POS grid, inventory lists, details).
///
/// Uses the photo sent with the staff inventory ([imageUrl]) and otherwise the
/// loaded catalog's main photo; with neither (none uploaded, or offline before
/// the photo was ever loaded) it shows the product's icon tile, same as the
/// customer app. Rebuilds when the catalog finishes loading.
class StaffProductPhoto extends StatelessWidget {
  final String productId;
  final String? imageUrl;

  /// Square side; double.infinity fills the parent.
  final double size;
  final BorderRadius? borderRadius;

  const StaffProductPhoto({
    super.key,
    required this.productId,
    this.imageUrl,
    this.size = 40,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ProductsRepository.instance,
      builder: (context, _) => ProductThumbnail(
        product: findProductById(productId),
        imageUrl: (imageUrl != null && imageUrl!.isNotEmpty) ? imageUrl : null,
        size: size,
        borderRadius: borderRadius ?? BorderRadius.circular(10),
      ),
    );
  }
}
