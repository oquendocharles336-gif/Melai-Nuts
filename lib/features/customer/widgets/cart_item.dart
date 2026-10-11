import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../cart_controller.dart';
import 'product_card.dart';

/// A single editable row in the Cart screen: thumbnail, name/variant,
/// quantity stepper, remove action, and line total.
class CartItemTile extends StatelessWidget {
  final CartLine line;
  final ValueChanged<int> onQuantityChanged;
  final VoidCallback onRemove;

  const CartItemTile({
    super.key,
    required this.line,
    required this.onQuantityChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProductThumbnail(product: line.product, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        line.product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.labelLg,
                      ),
                    ),
                    InkWell(
                      onTap: onRemove,
                      child: const Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Variant: ${line.variant.label}',
                  style: AppTextStyles.bodySm,
                ),
                Text(
                  'Unit price: ₱${line.unitPrice.toStringAsFixed(2)}',
                  style: AppTextStyles.bodySm,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _QtyStepper(
                      quantity: line.quantity,
                      onChanged: onQuantityChanged,
                    ),
                    Text(
                      '₱${line.lineTotal.toStringAsFixed(0)}',
                      style: AppTextStyles.titleMd.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  final int quantity;
  final ValueChanged<int> onChanged;

  const _QtyStepper({required this.quantity, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.remove_rounded, size: 16),
            onPressed: () => onChanged(quantity - 1),
          ),
          SizedBox(
            width: 20,
            child: Text(
              '$quantity',
              textAlign: TextAlign.center,
              style: AppTextStyles.labelLg,
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.add_rounded, size: 16),
            onPressed: () => onChanged(quantity + 1),
          ),
        ],
      ),
    );
  }
}
