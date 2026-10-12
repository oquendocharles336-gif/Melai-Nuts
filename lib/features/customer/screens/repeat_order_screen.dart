import 'package:flutter/material.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/order.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/products_repository.dart';
import '../cart_controller.dart';
import 'cart_screen.dart';

/// Finds the live catalogue product/variant for a past order line: by the
/// stored `product_id` / `variant_id` first (renamed products still match),
/// then by exact name/label for lines from before those ids were kept.
/// Returns null when the product is gone; a null variant when only the
/// option is gone. Never swaps in a different option.
({Product product, ProductVariant? variant})? matchOrderLine(OrderItem item, List<Product> catalog) {
  Product? product;
  ProductVariant? variant;
  if (item.variantId != null) {
    for (final p in catalog) {
      for (final v in p.variants) {
        if (v.id == item.variantId) {
          product = p;
          variant = v;
        }
      }
    }
  }
  if (product == null && item.productId != null) {
    for (final p in catalog) {
      if (p.id == item.productId) product = p;
    }
  }
  product ??= catalog.where((p) => p.name.toLowerCase() == item.productName.toLowerCase()).firstOrNull;
  if (product == null) return null;
  variant ??= product.variants.where((v) => v.label.toLowerCase() == item.variantLabel.toLowerCase()).firstOrNull;
  return (product: product, variant: variant);
}

/// Outcome of trying to re-add one line from the original order: either it
/// was added (optionally at a reduced quantity, if stock ran short) or it
/// was skipped, with a real, specific reason the customer can see.
class _RepeatLineResult {
  final OrderItem item;
  final bool added;
  final int quantityAdded;
  final String? note;

  const _RepeatLineResult({
    required this.item,
    required this.added,
    this.quantityAdded = 0,
    this.note,
  });
}

/// Confirmation step for "Repeat Order": review the previous order's items
/// and add them all back to the cart in one tap.
///
/// Matches each item to a current [Product] + [ProductVariant] by exact
/// name so it can be added through the same [CartController] used
/// everywhere else — verifying, for each line, that the product still
/// exists and is active, that the exact variant still exists, and that
/// there's real stock for it at the current branch, and always adding at
/// today's price (never the order's old `unitPrice`) since [Product] and
/// [ProductVariant] here come straight from the live, branch-scoped
/// catalog in `kProducts`.
class RepeatOrderScreen extends StatelessWidget {
  final Order order;

  const RepeatOrderScreen({super.key, required this.order});

  List<_RepeatLineResult> _repeat() {
    final results = <_RepeatLineResult>[];
    for (final item in order.items) {
      final match = matchOrderLine(item, kProducts);
      final product = match?.product;
      final variant = match?.variant;
      if (product == null) {
        results.add(_RepeatLineResult(item: item, added: false, note: 'No longer available'));
        continue;
      }
      if (variant == null) {
        results.add(_RepeatLineResult(
          item: item,
          added: false,
          note: '"${item.variantLabel}" option is no longer available',
        ));
        continue;
      }

      if (variant.isOutOfStock) {
        results.add(_RepeatLineResult(item: item, added: false, note: 'Out of stock right now'));
        continue;
      }

      // addProduct caps at the stock still available (minus what's already
      // in the cart) and says why when nothing could be added.
      final result = CartController.instance.addProduct(product, variant, quantity: item.quantity);
      if (!result.ok) {
        results.add(_RepeatLineResult(
          item: item,
          added: false,
          note: result.message ?? 'Could not be added',
        ));
        continue;
      }
      final quantityAdded = result.added;
      results.add(_RepeatLineResult(
        item: item,
        added: true,
        quantityAdded: quantityAdded,
        note: result.isPartial ? 'Only $quantityAdded of ${item.quantity} in stock — added what\'s available' : null,
      ));
    }
    return results;
  }

  Future<void> _handleRepeat(BuildContext context) async {
    // Stock is per branch: pick one first (or auto-pick the only one) rather
    // than reporting every line as unavailable.
    if (CartController.instance.signedInUid != null &&
        BranchController.instance.selectedBranch == null) {
      final picked = await ensureBranchSelected(context);
      if (!context.mounted) return;
      if (!picked) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Please select a branch to repeat this order.')));
        return;
      }
    }
    // Availability is judged against the live catalog, so never do it against
    // one that failed to load — that would wrongly report every item as
    // "no longer available". Try to load it, and say so plainly if we can't.
    final catalog = ProductsRepository.instance;
    if (!catalog.hasLoaded) {
      await catalog.loadCatalog(
        branchId: BranchController.instance.selectedBranch?.id,
      );
      if (!context.mounted) return;
      if (!catalog.hasLoaded) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                catalog.error?.message ??
                    'We couldn\'t load current products. Please try again.',
              ),
            ),
          );
        return;
      }
    }

    final results = _repeat();
    final addedCount = results.where((r) => r.added).length;
    final unavailable = results.where((r) => !r.added).toList();
    final capped = results.where((r) => r.added && r.note != null).toList();

    final navigator = Navigator.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(addedCount == 0 ? 'Nothing could be added' : 'Added to your cart'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (addedCount > 0)
                Text('$addedCount item(s) from ${order.id} were added at today\'s prices.'),
              for (final r in capped)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('• ${r.item.productName}: ${r.note}', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
                ),
              if (unavailable.isNotEmpty) ...[
                const Padding(padding: EdgeInsets.only(top: 8), child: Divider()),
                Text('Could not add:', style: AppTextStyles.labelLg),
                for (final r in unavailable)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• ${r.item.productName} (${r.item.variantLabel}): ${r.note}', style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (addedCount == 0 || !context.mounted) return;
    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const CartScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Repeat Order', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Repeat Order adds the exact items from ${order.id} to your active cart for instant checkout.',
                      style: AppTextStyles.bodyMd,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Items from ${order.id}', style: AppTextStyles.titleMd),
            const SizedBox(height: AppSpacing.sm),
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.productName, style: AppTextStyles.labelLg),
                            Text(item.variantLabel, style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                      Text('${item.quantity}x', style: AppTextStyles.bodyMd),
                      const SizedBox(width: 12),
                      Text(
                        '₱${item.total.toStringAsFixed(0)}',
                        style: AppTextStyles.labelLg.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Order Total', style: AppTextStyles.titleMd),
                  Text(
                    '₱${order.total.toStringAsFixed(0)}',
                    style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Add All to Cart',
              icon: Icons.shopping_cart_checkout_rounded,
              onPressed: () => _handleRepeat(context),
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
