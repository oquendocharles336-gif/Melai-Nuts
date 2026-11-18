import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/pending_sync_chip.dart';
import '../../../core/widgets/primary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/inventory_batch.dart';

/// Confirms the database saved the stock adjustment, showing the
/// before/after numbers (of the adjusted batch) — e.g. Current Stock: 25, Adjustment: +10,
/// New Stock: 35.
class InventoryAdjustmentSuccessScreen extends StatelessWidget {
  final String productId;
  final InventoryBatch batch;
  final int adjustment;
  final int newStock;

  /// Saved on this device while offline; it syncs when the connection returns.
  final bool pendingSync;

  const InventoryAdjustmentSuccessScreen({
    super.key,
    required this.productId,
    required this.batch,
    required this.adjustment,
    required this.newStock,
    this.pendingSync = false,
  });

  @override
  Widget build(BuildContext context) {
    final product = findProductById(productId);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(AppSpacing.xl),
                decoration: const BoxDecoration(color: AppColors.successBg, shape: BoxShape.circle),
                child: const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 84),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(pendingSync ? 'Adjustment Saved' : 'Inventory Updated!', style: AppTextStyles.headlineLg, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                '${batch.productName.isNotEmpty ? batch.productName : product.name} • Batch ${batch.batchCode}',
                style: AppTextStyles.bodyMd,
                textAlign: TextAlign.center,
              ),
              if (pendingSync) ...[
                const SizedBox(height: 10),
                const PendingSyncChip(),
                const SizedBox(height: 6),
                Text(
                  'Saved on this device and recorded as a stock movement. It is sent to the server automatically when the connection returns.',
                  style: AppTextStyles.bodySm,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.sm,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _StockNumber(label: 'Previous', value: '${newStock - adjustment}'),
                    const Icon(Icons.arrow_forward_rounded, color: AppColors.textSecondary),
                    _StockNumber(
                      label: 'Adjustment',
                      value: '${adjustment >= 0 ? '+' : ''}$adjustment',
                      valueColor: adjustment >= 0 ? AppColors.success : AppColors.error,
                    ),
                    const Icon(Icons.arrow_forward_rounded, color: AppColors.textSecondary),
                    _StockNumber(label: 'New Stock', value: '$newStock', valueColor: AppColors.roleStaff),
                  ],
                ),
              ),
              const Spacer(),
              PrimaryButton(
                label: 'Back to Inventory',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.of(context).popUntil((r) => r.settings.name == AppRoutes.staffHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StockNumber extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StockNumber({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppTextStyles.headlineSm.copyWith(color: valueColor)),
        Text(label, style: AppTextStyles.bodySm, textAlign: TextAlign.center),
      ],
    );
  }
}
