import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/product.dart';
import 'storefront_widgets.dart';

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
          // Fades the photo in once it arrives instead of popping.
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child: child,
            );
          },
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

/// Standard product grid/list card: photo, name, rating, price, and an
/// Add button that becomes a − qty + stepper once the product is in the
/// cart. Used on the Home, Catalog, Category, and Search screens.
///
/// In a grid cell or a horizontal strip (bounded height) the photo takes
/// the space left over; in a vertical list it keeps a fixed height.
class ProductCard extends StatefulWidget {
  final Product product;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  /// One less in the cart. Null keeps the plain "N in cart" button.
  final VoidCallback? onDecrease;
  final int quantityInCart;

  const ProductCard({
    super.key,
    required this.product,
    required this.onTap,
    required this.onAdd,
    this.onDecrease,
    this.quantityInCart = 0,
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  bool _pressed = false;

  static const double _listImageHeight = 140;

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final radius = BorderRadius.circular(AppSpacing.radiusMd);
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: _pressed ? AppColors.outlineButton : AppColors.border),
          boxShadow: _pressed ? AppShadows.md : AppShadows.sm,
        ),
        child: Material(
          color: AppColors.surfaceContainer,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (down) {
              if (mounted && _pressed != down) setState(() => _pressed = down);
            },
            splashColor: AppColors.primaryContainer.withValues(alpha: 0.6),
            highlightColor: AppColors.primaryContainer.withValues(alpha: 0.25),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bounded = constraints.hasBoundedHeight;
                  final photo = _photo(product);
                  return Column(
                    mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (bounded) Expanded(child: photo) else SizedBox(height: _listImageHeight, child: photo),
                      const SizedBox(height: 8),
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.labelLg,
                      ),
                      // Only shown once real reviews exist: a "0.0 (0)" rating
                      // on every card would look like made-up star ratings.
                      if (product.reviewCount > 0) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.star_rounded, size: 14, color: AppColors.warning),
                            const SizedBox(width: 2),
                            Flexible(
                              child: Text(
                                '${product.rating.toStringAsFixed(1)} (${product.reviewCount})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.bodySm,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: Text(
                              pesoWhole(product.price),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.titleMd.copyWith(color: AppColors.primary),
                            ),
                          ),
                          if (product.originalPrice != null) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                pesoWhole(product.originalPrice!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.bodySm.copyWith(decoration: TextDecoration.lineThrough),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      _CardAction(
                        productName: product.name,
                        quantity: widget.quantityInCart,
                        onAdd: product.isOutOfStock ? null : widget.onAdd,
                        onDecrease: widget.onDecrease,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _photo(Product product) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ProductThumbnail(
          product: product,
          size: double.infinity,
          borderRadius: BorderRadius.circular(12),
        ),
        if (product.badge != null)
          Positioned(
            top: 6,
            left: 6,
            child: _Pill(label: product.badge!, background: AppColors.honey, foreground: AppColors.ink),
          ),
        // Real stock/availability state, only when it isn't the default
        // "In Stock". Before a branch is chosen the catalog holds the
        // all-branches total, so it says "Turn on location" instead.
        Positioned(
          top: 6,
          right: 6,
          left: product.badge != null ? null : 6,
          child: Align(
            alignment: Alignment.topRight,
            child: ListenableBuilder(
              listenable: BranchController.instance,
              builder: (context, _) {
                final chip = CustomerStockChip.of(product);
                if (!chip.worthShowing) return const SizedBox.shrink();
                return _Pill(label: chip.label, background: chip.background, foreground: chip.foreground);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _Pill({required this.label, required this.background, required this.foreground});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.labelSm.copyWith(color: foreground),
      ),
    );
  }
}

/// The bottom of a card: Add, the − qty + stepper, or Unavailable.
class _CardAction extends StatelessWidget {
  final String productName;
  final int quantity;

  /// Null means this product can't be added right now (out of stock).
  final VoidCallback? onAdd;
  final VoidCallback? onDecrease;

  const _CardAction({
    required this.productName,
    required this.quantity,
    required this.onAdd,
    required this.onDecrease,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radiusSm + 4));
    final Widget child;
    if (quantity > 0 && onDecrease != null) {
      child = QuantityStepper(
        key: const ValueKey('stepper'),
        quantity: quantity,
        itemName: productName,
        onDecrease: onDecrease!,
        onIncrease: onAdd,
      );
    } else if (onAdd == null && quantity == 0) {
      child = Container(
        key: const ValueKey('unavailable'),
        height: QuantityStepper.height,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: AppColors.errorBg, shape: shape),
        child: Text('Unavailable', style: AppTextStyles.labelMd.copyWith(color: AppColors.error)),
      );
    } else {
      final inCart = quantity > 0;
      child = SizedBox(
        key: const ValueKey('add'),
        height: QuantityStepper.height,
        width: double.infinity,
        child: Semantics(
          button: true,
          label: inCart ? 'Add one more $productName, $quantity in cart' : 'Add $productName to cart',
          excludeSemantics: true,
          child: FilledButton.icon(
            onPressed: onAdd,
            style: FilledButton.styleFrom(
              backgroundColor: inCart ? AppColors.successBg : AppColors.primary,
              foregroundColor: inCart ? AppColors.success : AppColors.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, QuantityStepper.height),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: shape,
            ),
            icon: Icon(inCart ? Icons.check_rounded : Icons.add_shopping_cart_rounded, size: 18),
            label: Text(inCart ? '$quantity in cart' : 'Add', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween<double>(begin: 0.9, end: 1).animate(animation), child: child),
      ),
      child: child,
    );
  }
}

/// The stock label a customer should see for [product]. Stock is per branch,
/// so with no branch chosen the catalog's all-branches total is not shown as
/// "In Stock" (the customer could then fail at their real branch).
class CustomerStockChip {
  static const String chooseBranchLabel = 'Turn on location to see stock';

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
