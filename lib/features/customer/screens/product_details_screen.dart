import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/product.dart';
import '../../../data/models/promotion.dart';
import '../../../data/repositories/products_repository.dart';
import '../cart_controller.dart';
import '../widgets/product_card.dart';
import 'cart_screen.dart';
import 'checkout_screen.dart';

/// Customer-facing product details: variant/size picker, spice level,
/// branch availability, Add to Cart and Buy Now (matches the prototype's
/// "Product Details" screen with variant selection).
class ProductDetailsScreen extends StatefulWidget {
  final Product product;

  const ProductDetailsScreen({super.key, required this.product});

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  late ProductVariant _selectedVariant = widget.product.variants.first;
  String? _selectedSpiceLevel;
  int _quantity = 1;
  bool _busy = false;

  List<Promotion> _promotions = const [];
  bool _loadingPromotions = true;

  @override
  void initState() {
    super.initState();
    if (widget.product.spiceLevels.isNotEmpty) {
      _selectedSpiceLevel = widget.product.spiceLevels.first;
    }
    _loadPromotions();
  }

  Future<void> _loadPromotions() async {
    List<Promotion> promos = const [];
    try {
      promos = await AppErrors.guard(
        () => ProductsRepository.instance.fetchApplicablePromotions(
          productId: widget.product.id,
          categoryId: widget.product.categoryId,
        ),
        scope: ErrorScope.catalog,
      );
    } catch (_) {
      // Promotions are a nice-to-have. If they can't load, the section stays
      // hidden and ordering is unaffected — no error popup for this.
    }
    if (!mounted) return;
    setState(() {
      _promotions = promos;
      _loadingPromotions = false;
    });
  }

  /// Re-checks live stock and adds to cart. Returns the quantity actually
  /// added (see [CartController.addProductWithLiveCheck]), or null if the
  /// check itself failed — in which case the customer has already been told
  /// why (offline, timeout, expired session, ...).
  Future<int?> _addToCart() async {
    setState(() => _busy = true);
    try {
      return await AppErrors.guard(
        () => CartController.instance.addProductWithLiveCheck(
          widget.product,
          _selectedVariant,
          quantity: _quantity,
        ),
        scope: ErrorScope.cart,
      );
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e, scope: ErrorScope.cart);
      return null;
    } finally {
      // Always release the buttons, even when the request throws.
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _unavailableMessage =>
      widget.product.isActive ? 'This item is out of stock.' : 'This item is no longer available.';

  Future<void> _handleAddToCart() async {
    final added = await _addToCart();
    if (!mounted || added == null) return;
    if (added <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_unavailableMessage)));
      return;
    }
    final message = added < _quantity
        ? 'Only $added available — added $added to cart (stock limit reached).'
        : 'Added ${widget.product.name} to cart';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'View Cart',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CartScreen()),
          ),
        ),
      ),
    );
  }

  /// Adds the current selection to the cart (re-checking live stock, same
  /// as [_handleAddToCart]) and, only if that actually succeeded, goes
  /// straight to Checkout — it never forwards the customer to checkout for
  /// an item that just turned out to be unavailable or when the check failed.
  Future<void> _handleBuyNow() async {
    final added = await _addToCart();
    if (!mounted || added == null) return;
    if (added <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_unavailableMessage)));
      return;
    }
    if (added < _quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only $added available — added $added to cart.')),
      );
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CheckoutScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Product Details', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            AspectRatio(
              aspectRatio: 1.4,
              child: ProductThumbnail(
                product: product,
                size: double.infinity,
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (product.badge != null)
                  _Pill(label: product.badge!, color: AppColors.primaryContainer, textColor: AppColors.primaryDark),
                _Pill(label: product.stockLabel, color: product.stockLabelBg, textColor: product.stockLabelColor),
              ],
            ),
            const SizedBox(height: 8),
            Text(product.name, style: AppTextStyles.headlineMd),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '₱${_selectedVariant.price.toStringAsFixed(0)}',
                  style: AppTextStyles.headlineMd.copyWith(color: AppColors.primary),
                ),
                if (product.originalPrice != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '₱${product.originalPrice!.toStringAsFixed(0)}',
                    style: AppTextStyles.bodyMd.copyWith(
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ],
              ],
            ),
            // Only shown once real reviews exist — no fabricated rating.
            if (product.reviewCount > 0) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.star_rounded, size: 16, color: AppColors.warning),
                  const SizedBox(width: 4),
                  Text(
                    '${product.rating.toStringAsFixed(1)} · ${product.reviewCount} customer reviews',
                    style: AppTextStyles.bodySm,
                  ),
                ],
              ),
            ],
            if (!product.isActive) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.errorBg,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This product has been taken off the menu and can no longer be ordered.',
                        style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Real merchandising tags from `products.tags` — never invented.
            if (product.tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in product.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        tag,
                        style: AppTextStyles.labelSm.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LAGUNA ROASTERY PROFILE', style: AppTextStyles.labelSm),
                  const SizedBox(height: 6),
                  Text(product.description, style: AppTextStyles.bodyMd),
                ],
              ),
            ),
            // Applicable Promotions — real, staff-configured rows targeting
            // this product or its category (`promotions.product_id` /
            // `category_id`). Hidden entirely while loading or when none
            // apply, rather than showing a placeholder offer.
            if (!_loadingPromotions && _promotions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Applicable Promotions', style: AppTextStyles.titleMd),
              const SizedBox(height: AppSpacing.sm),
              for (final promo in _promotions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        Icon(promo.icon, color: AppColors.primaryDark, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(promo.badgeLabel, style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
                              Text(promo.title, style: AppTextStyles.labelLg),
                              if (promo.subtitle.isNotEmpty)
                                Text(promo.subtitle, style: AppTextStyles.bodySm),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Select Size & Packaging', style: AppTextStyles.titleMd),
            const SizedBox(height: AppSpacing.sm),
            for (final variant in product.variants)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _VariantTile(
                  variant: variant,
                  selected: _selectedVariant.label == variant.label,
                  onTap: () => setState(() {
                    _selectedVariant = variant;
                    final stock = variant.stockOnHand;
                    if (stock != null && _quantity > stock) {
                      _quantity = stock < 1 ? 1 : stock;
                    }
                  }),
                ),
              ),
            if (product.spiceLevels.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Spice Level Profile', style: AppTextStyles.titleMd),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final level in product.spiceLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: _selectedSpiceLevel == level,
                      onSelected: (_) => setState(() => _selectedSpiceLevel = level),
                      selectedColor: AppColors.primaryContainer,
                      labelStyle: AppTextStyles.labelLg.copyWith(
                        color: _selectedSpiceLevel == level
                            ? AppColors.primaryDark
                            : AppColors.textMuted,
                      ),
                      side: BorderSide(
                        color: _selectedSpiceLevel == level
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Container(
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
                      const Icon(Icons.storefront_outlined, size: 18, color: AppColors.darkBrown),
                      const SizedBox(width: 8),
                      Text('Branch Inventory', style: AppTextStyles.titleMd),
                      const Spacer(),
                      Text('● Live Sync', style: AppTextStyles.bodySm.copyWith(color: AppColors.success)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final branch in product.branchAvailability)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(branch, style: AppTextStyles.bodyMd)),
                          Text('In Stock', style: AppTextStyles.bodySm.copyWith(color: AppColors.success)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
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
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_rounded),
                        onPressed: () => setState(() {
                          if (_quantity > 1) _quantity--;
                        }),
                      ),
                      Text('$_quantity', style: AppTextStyles.titleMd),
                      IconButton(
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () => setState(() {
                          final stock = _selectedVariant.stockOnHand;
                          if (stock == null || _quantity < stock) _quantity++;
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Builder(builder: (context) {
                    final unavailable = !product.isActive ||
                        (_selectedVariant.stockOnHand ?? 1) <= 0;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PrimaryButton(
                          label: !product.isActive
                              ? 'Unavailable'
                              : unavailable
                                  ? 'Out of Stock'
                                  : 'Add to Cart • ₱${(_selectedVariant.price * _quantity).toStringAsFixed(0)}',
                          icon: Icons.shopping_cart_outlined,
                          loading: _busy,
                          onPressed: unavailable ? null : _handleAddToCart,
                        ),
                        const SizedBox(height: 8),
                        SecondaryButton(
                          label: 'Buy Now',
                          icon: Icons.bolt_rounded,
                          onPressed: (unavailable || _busy) ? null : _handleBuyNow,
                        ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _Pill({required this.label, required this.color, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: AppTextStyles.labelMd.copyWith(color: textColor)),
    );
  }
}

class _VariantTile extends StatelessWidget {
  final ProductVariant variant;
  final bool selected;
  final VoidCallback onTap;

  const _VariantTile({required this.variant, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryContainer.withValues(alpha: 0.35) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.6 : 1),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Text(variant.label, style: AppTextStyles.labelLg),
                  if (variant.badge != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.darkBrown,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        variant.badge!,
                        style: AppTextStyles.labelSm.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text('₱${variant.price.toStringAsFixed(0)}', style: AppTextStyles.titleMd),
          ],
        ),
      ),
    );
  }
}
