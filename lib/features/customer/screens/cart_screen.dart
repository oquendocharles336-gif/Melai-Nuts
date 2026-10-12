import 'package:flutter/material.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../cart_controller.dart';
import '../widgets/cart_item.dart';
import 'checkout_screen.dart';
import 'product_catalog_screen.dart';

/// True while the cart on screen may differ from the one the server holds
/// (a save is running, or edits haven't been accepted yet).
bool cartBlocksCheckout(CartController cart) => cart.isSyncing || cart.hasUnsyncedChanges;

/// Why "Proceed to Checkout" is off, or null when it is on.
String? checkoutBlockedReason(CartController cart) {
  if (cart.isSyncing) return 'Saving your cart...';
  if (cart.hasUnsyncedChanges) {
    return 'Your cart changes aren\'t saved yet. Please check your connection.';
  }
  return null;
}

/// "My Cart" — editable line items, loyalty points redemption, voucher
/// code, order summary, and Proceed to Checkout (matches the prototype's
/// Shopping Cart screen).
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _voucherController = TextEditingController();
  String? _voucherError;

  @override
  void dispose() {
    _voucherController.dispose();
    super.dispose();
  }

  /// Remove one line — asks first, then offers Undo.
  Future<void> _removeLine(CartLine line) async {
    final cart = CartController.instance;
    final t = AppLocalizations.of(context);
    final name = '${line.product.name} (${line.variant.label})';
    if (!await ConfirmDialog.remove(context, name)) return;
    if (!mounted) return;
    final index = cart.lines.indexWhere((l) => l.id == line.id);
    final messenger = ScaffoldMessenger.of(context);
    await cart.removeLine(line.id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(t.removedSnack(name)),
        action: SnackBarAction(label: t.undo, onPressed: () => cart.restoreLine(line, index)),
      ));
  }

  /// Clear the whole cart — asks first (Cancel | Clear Cart).
  Future<void> _clearCart() async {
    final cart = CartController.instance;
    final t = AppLocalizations.of(context);
    final ok = await ConfirmDialog.show(
      context,
      title: t.clearCartTitle,
      message: t.clearCartMessage(cart.itemCount),
      confirmLabel: t.clearCart,
      icon: Icons.remove_shopping_cart_outlined,
    );
    if (ok) await cart.clear();
  }

  Future<void> _applyVoucher() async {
    final error = ValidationUtils.validateVoucherCode(_voucherController.text);
    setState(() => _voucherError = error);
    if (error != null) return;
    final messenger = ScaffoldMessenger.of(context);
    final serverError = await CartController.instance.applyVoucher(_voucherController.text.trim());
    if (!mounted) return;
    if (serverError == null) return;
    setState(() => _voucherError = serverError);
    messenger.showSnackBar(SnackBar(content: Text(serverError)));
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) => Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: MelaiAppBar(
          title: 'My Cart (${cart.itemCount} Items)',
          showBack: true,
          actions: [
            if (cart.lines.isNotEmpty)
              TextButton(
                onPressed: cart.isSyncing ? null : _clearCart,
                child: const Text('Clear cart'),
              ),
          ],
        ),
        body: SafeArea(
          child: cart.lines.isEmpty
              // loading -> error (+ retry) -> genuinely empty, in that order,
              // so an unfinished or failed load never reads as "cart is empty".
              ? (cart.isHydrating
                  ? const StateLoadingView(message: 'Loading your cart...')
                  : cart.hasLoadError
                      ? StateErrorView(
                          message: cart.lastError,
                          scope: ErrorScope.cart,
                          onRetry: () => cart.retryLoad(),
                        )
                      : const _EmptyCart())
              : ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.successBg,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: AppShadows.sm,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: AppColors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'In Stock — Fulfilling from ${cart.currentBranch}',
                        style: AppTextStyles.labelMd.copyWith(color: AppColors.success),
                      ),
                    ),
                    Text('Change Branch', style: AppTextStyles.labelMd),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final line in cart.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: CartItemTile(
                    line: line,
                    // Going below 1 is a removal: it asks first, like the bin icon.
                    onQuantityChanged: (q) => q <= 0 ? _removeLine(line) : cart.updateQuantity(line.id, q),
                    onRemove: () => _removeLine(line),
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.sm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.workspace_premium_rounded, size: 18, color: AppColors.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Redeem Golden Kernel Points', style: AppTextStyles.labelLg),
                          Text('Balance: ${cart.loyaltyPointsBalance} pts', style: AppTextStyles.bodySm),
                        ],
                      ),
                    ),
                    Switch(
                      value: cart.redeemPoints,
                      activeThumbColor: AppColors.primary,
                      onChanged: cart.isSyncing || cart.loyaltyPointsBalance <= 0
                          ? null
                          : (v) async {
                        final messenger = ScaffoldMessenger.of(context);
                        final error = await cart.setRedeemPoints(v);
                        if (!mounted) return;
                        if (error == null) return;
                        messenger.showSnackBar(
                          SnackBar(content: Text(error)),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (cart.lastError != null && cart.isSyncing == false)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    cart.lastError!,
                    style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Text('Pasalubong Voucher', style: AppTextStyles.labelLg),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _voucherController,
                      inputFormatters: InputRules.voucherCode(),
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      onChanged: (_) {
                        if (_voucherError != null) setState(() => _voucherError = null);
                      },
                      onSubmitted: (_) => _applyVoucher(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.confirmation_number_outlined, size: 20),
                        hintText: 'Enter voucher code',
                        errorText: _voucherError,
                        errorMaxLines: 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: cart.isSyncing ? null : _applyVoucher,
                    child: cart.isSyncing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Apply'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ORDER SUMMARY', style: AppTextStyles.labelSm),
                    const SizedBox(height: 10),
                    _SummaryRow('Subtotal (${cart.itemCount} packs)', '₱${cart.subtotal.toStringAsFixed(0)}'),
                    if (cart.appliedVoucherCode != null)
                      _SummaryRow('Promo Discount (${cart.appliedVoucherCode})', '-₱${cart.voucherDiscount.toStringAsFixed(0)}', valueColor: AppColors.success),
                    if (cart.redeemPoints)
                      _SummaryRow('Loyalty Points Discount', '-₱${cart.loyaltyDiscount.toStringAsFixed(0)}', valueColor: AppColors.success),
                    _SummaryRow('Est. Delivery Fee', '₱${cart.deliveryFee.toStringAsFixed(0)}'),
                    const Divider(height: 20),
                    _SummaryRow('Total Payable', '₱${cart.total.toStringAsFixed(0)}', isTotal: true),
                    Text('The final total is confirmed by the branch when you place the order.', style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: cart.lines.isEmpty
            ? const SizedBox.shrink()
            : Container(
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
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TOTAL AMOUNT', style: AppTextStyles.bodySm),
                        Text(
                          '₱${cart.total.toStringAsFixed(0)}',
                          style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                        ),
                        if (checkoutBlockedReason(cart) case final reason?)
                          Text(
                            reason,
                            key: const ValueKey('checkout-blocked-reason'),
                            style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Proceed to Checkout',
                      // Checkout uses the cart the server holds, so it waits
                      // until the server has accepted what is shown here.
                      onPressed: cartBlocksCheckout(cart) ? null : () {
                        // Placing an order requires a signed-in customer.
                        if (AuthService.instance.currentFirebaseUser == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Please sign in to place your order.'),
                            ),
                          );
                          Navigator.of(context).pushNamed(AppRoutes.login);
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool isTotal;

  const _SummaryRow(this.label, this.value, {this.valueColor, this.isTotal = false});

  @override
  Widget build(BuildContext context) {
    final style = isTotal
        ? AppTextStyles.headlineSm
        : AppTextStyles.bodyMd.copyWith(color: AppColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(value, style: style.copyWith(color: valueColor ?? (isTotal ? AppColors.primary : null))),
        ],
      ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(
                color: AppColors.surfaceContainerLow,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.shopping_bag_outlined, size: 44, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            Text('Your cart is empty', style: AppTextStyles.headlineSm),
            const SizedBox(height: 6),
            Text(
              'Browse the catalog and add some freshly roasted nuts!',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd,
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'Browse Catalog',
              icon: Icons.storefront_outlined,
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const ProductCatalogScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}