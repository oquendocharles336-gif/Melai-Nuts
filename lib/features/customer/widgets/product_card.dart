import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/motion.dart';
import '../../../data/models/product.dart';

/// Product "photo" tile: the real uploaded product image when one exists,
/// otherwise an on-brand gradient placeholder with the product's icon —
/// never a fake/stock photo standing in for a real product picture.
class ProductThumbnail extends StatelessWidget {
  final Product product;
  final double size;
  final BorderRadius? borderRadius;

  const ProductThumbnail({
    super.key,
    required this.product,
    this.size = 84,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(14);
    if (product.images.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.network(
          product.images.first,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // A broken/expired image URL falls back to the placeholder
          // instead of Flutter's default error icon.
          errorBuilder: (context, error, stackTrace) => _placeholder(radius),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _placeholder(radius);
          },
        ),
      );
    }
    return _placeholder(radius);
  }

  Widget _placeholder(BorderRadius radius) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            product.color.withValues(alpha: 0.20),
            product.color.withValues(alpha: 0.08),
          ],
        ),
      ),
      // `size` is double.infinity when the tile fills its parent (cards).
      child: Icon(product.icon, color: product.color, size: size.isFinite ? size * 0.42 : 56),
    );
  }
}

/// Standard product grid/list card: thumbnail, name, rating, price, and an
/// Add button. Used on the Home, Catalog, Category, and Search screens.
class ProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final int quantityInCart;

  const ProductCard({
    super.key,
    required this.product,
    required this.onTap,
    required this.onAdd,
    this.quantityInCart = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.md,
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                // Fixed-height image container to avoid infinite height constraints
                // in unconstrained parents like Columns or ListViews.
                SizedBox(
                  height: 140,
                  width: double.infinity,
                  child: ProductThumbnail(
                    product: product,
                    size: double.infinity,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                if (product.badge != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.darkBrown,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        product.badge!,
                        style: AppTextStyles.labelSm.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                // Real stock/availability state — only shown when it isn't
                // the default "In Stock" (nothing to flag there). Before a
                // branch is chosen the catalog holds the all-branches total,
                // so it says "Choose a branch" instead of implying stock here.
                Positioned(
                  top: 6,
                  right: 6,
                  child: ListenableBuilder(
                    listenable: BranchController.instance,
                    builder: (context, _) {
                      final chip = CustomerStockChip.of(product);
                      if (!chip.worthShowing) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: chip.background,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          chip.label,
                          style: AppTextStyles.labelSm.copyWith(color: chip.foreground),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelLg,
            ),
            // Only shown once real reviews exist — a "0.0 (0)" rating on
            // every card would look like fabricated star ratings.
            if (product.reviewCount > 0) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(Icons.star_rounded, size: 14, color: AppColors.warning),
                  const SizedBox(width: 2),
                  Text(
                    '${product.rating.toStringAsFixed(1)} (${product.reviewCount})',
                    style: AppTextStyles.bodySm,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '₱${product.price.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (product.originalPrice != null)
                        Text(
                          '₱${product.originalPrice!.toStringAsFixed(0)}',
                          style: AppTextStyles.bodySm.copyWith(
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                    ],
                  ),
                ),
                _AddButton(
                  quantity: quantityInCart,
                  onAdd: product.isOutOfStock ? null : onAdd,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final int quantity;

  /// Null means this product can't be added right now (out of stock).
  final VoidCallback? onAdd;

  const _AddButton({required this.quantity, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    if (onAdd == null && quantity == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.errorBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text('Unavailable', style: AppTextStyles.labelSm.copyWith(color: AppColors.error)),
      );
    }
    if (quantity > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.successBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_rounded, size: 14, color: AppColors.success),
            const SizedBox(width: 3),
            Text(
              '$quantity',
              style: AppTextStyles.labelSm.copyWith(color: AppColors.success),
            ),
          ],
        ),
      );
    }
    return Pressable(
      onTap: onAdd,
      pressedScale: 0.88,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.productCardGradientStart, AppColors.primaryDark],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 22),
      ),
    );
  }
}

/// The stock label a customer should see for [product]. Stock is per branch,
/// so with no branch chosen the catalog's all-branches total is not shown as
/// "In Stock" (the customer could then fail at their real branch).
class CustomerStockChip {
  static const String chooseBranchLabel = 'Choose a branch to see stock';

  final String label;
  final Color foreground;
  final Color background;

  /// False for the plain "In Stock" state, which cards don't flag.
  final bool worthShowing;

  const CustomerStockChip._(this.label, this.foreground, this.background, this.worthShowing);

  factory CustomerStockChip.of(Product product, {bool? branchChosen}) {
    final chosen = branchChosen ?? BranchController.instance.selectedBranch != null;
    // Zero across every branch is zero at any branch: still "Out of Stock".
    if (!chosen && !product.isOutOfStock) {
      return const CustomerStockChip._(
        chooseBranchLabel,
        AppColors.textSecondary,
        AppColors.surfaceContainerHigh,
        true,
      );
    }
    return CustomerStockChip._(
      product.stockLabel,
      product.stockLabelColor,
      product.stockLabelBg,
      product.isOutOfStock || product.isLowStock,
    );
  }
}
