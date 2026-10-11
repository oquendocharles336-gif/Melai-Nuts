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

/// Outcome of trying to re-add one line from the original order: either it
/// was added (optionally at a reduced quantity, if stock ran short) or it
/// was skipped, with a real, specific reason the customer can see —
/// `order_items` only stores a denormalized product name/variant label, so
/// there's no id to look up directly, and re-adding blindly (an unmatched
/// variant silently swapped for whichever one happens to be first, or an
/// out-of-stock item added anyway) would misrepresent what's actually in
/// the cart.
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
      Product? product;
      for (final p in kProducts) {
        // kProducts only ever holds active products for the currently
        // selected branch (see ProductsRepository.loadCatalog), so simply
        // not finding a match here already covers "no longer exists" and
        // "no longer active" — no separate isActive check needed.
        if (p.name.toLowerCase() == item.productName.toLowerCase()) {
          product = p;
          break;
        }
      }
      if (product == null) {
        results.add(_RepeatLineResult(item: item, added: false, note: 'No longer available'));
        continue;
      }

      ProductVariant? variant;
      for (final v in product.variants) {
        if (v.label.toLowerCase() == item.variantLabel.toLowerCase()) {
          variant = v;
          break;
        }
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

      final stock = variant.stockOnHand;
      final quantityToAdd = (stock != null && item.quantity > stock) ? stock : item.quantity;
      CartController.instance.addProduct(product, variant, quantity: quantityToAdd);
      final capped = quantityToAdd < item.quantity;
      results.add(_RepeatLineResult(
        item: item,
        added: true,
        quantityAdded: quantityToAdd,
        note: capped ? 'Only $quantityToAdd of ${item.quantity} in stock — added what\'s available' : null,
      ));
    }
    return results;
  }

  Future<void> _handleRepeat(BuildContext context) async {
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
