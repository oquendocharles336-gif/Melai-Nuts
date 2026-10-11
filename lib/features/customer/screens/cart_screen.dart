import 'package:flutter/material.dart';
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

  @override
  void dispose() {
    _voucherController.dispose();
    super.dispose();
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
                onPressed: cart.isSyncing ? null : () => cart.clear(),
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
                    onQuantityChanged: (q) => cart.updateQuantity(line.id, q),
                    onRemove: () => cart.removeLine(line.id),
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
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.confirmation_number_outlined, size: 20),
                        hintText: 'Enter voucher code',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: cart.isSyncing
                        ? null
                        : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final error = await cart.applyVoucher(_voucherController.text);
                      if (!mounted) return;
                      if (error == null) return;
                      messenger.showSnackBar(
                        SnackBar(content: Text(error)),
                      );
                    },
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
                    Text('Includes 12% Philippine VAT', style: AppTextStyles.bodySm),
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
                      ],
                    ),
                  ),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Proceed to Checkout',
                      onPressed: () {
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