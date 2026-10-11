import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../data/repositories/products_repository.dart';
import '../../../data/repositories/staff_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/primary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';

/// Editable pricing form for one product's variants — live margin
/// recalculation as COGS/SRP change. "Save Pricing" writes the prices to
/// Supabase through `staff_save_product` and reloads the shared catalog.
class ProductPricingScreen extends StatefulWidget {
  final String productId;

  const ProductPricingScreen({super.key, required this.productId});

  @override
  State<ProductPricingScreen> createState() => _ProductPricingScreenState();
}

class _VariantPricingControllers {
  final ProductVariant variant;
  final TextEditingController cogs;
  final TextEditingController srp;

  _VariantPricingControllers(this.variant)
      : cogs = TextEditingController(text: (variant.costPrice ?? 0).toStringAsFixed(2)),
        srp = TextEditingController(text: variant.price.toStringAsFixed(2));

  double get cogsValue => double.tryParse(cogs.text) ?? 0;
  double get srpValue => double.tryParse(srp.text) ?? 0;
  double get margin => srpValue == 0 ? 0 : ((srpValue - cogsValue) / srpValue) * 100;

  void dispose() {
    cogs.dispose();
    srp.dispose();
  }
}

class _ProductPricingScreenState extends State<ProductPricingScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Product _product = findProductById(widget.productId);
  late final List<_VariantPricingControllers> _rows =
      [for (final v in _product.variants) _VariantPricingControllers(v)];
  bool _saving = false;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final variants = [
        for (final r in _rows)
          {
            'id': r.variant.id,
            'label': r.variant.label,
            'price': r.srpValue,
            'cost_price': r.cogsValue > 0 ? r.cogsValue : null,
            'sku': r.variant.sku,
            'badge': r.variant.badge,
          },
      ];
      final lowest = _rows.isEmpty ? _product.price : _rows.map((r) => r.srpValue).reduce((a, b) => a < b ? a : b);
      await StaffRepository.instance.saveProduct(
        productId: _product.id,
        name: _product.name,
        description: _product.description,
        categoryId: _product.categoryId.isEmpty ? null : _product.categoryId,
        price: lowest,
        sku: _product.sku,
        images: _product.images,
        isActive: _product.isActive,
        isFeatured: _product.isFeatured,
        variants: variants,
      );
      await ProductsRepository.instance.loadCatalog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pricing updated for ${_product.name}.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is AppError ? e.message : 'Could not update pricing. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Edit Pricing • ${_product.name}', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
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
                        'Price changes sync to all connected POS registers and the customer storefront within 30 seconds.',
                        style: AppTextStyles.bodyMd,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final row in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _PricingRowCard(row: row, onChanged: () => setState(() {})),
                ),
              const SizedBox(height: AppSpacing.md),
              PrimaryButton(label: 'Save Pricing', icon: Icons.check_rounded, loading: _saving, onPressed: _save),
            ],
          ),
        ),
      ),
    );
  }
}

class _PricingRowCard extends StatelessWidget {
  final _VariantPricingControllers row;
  final VoidCallback onChanged;

  const _PricingRowCard({required this.row, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final healthy = row.margin >= 50;
    return Container(
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
          Text(row.variant.label, style: AppTextStyles.titleMd),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: row.cogs,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => onChanged(),
                  validator: (v) => ValidationUtils.validateNumber(v, fieldName: 'COGS', min: 0),
                  decoration: const InputDecoration(labelText: 'COGS (₱)', prefixIcon: Icon(Icons.receipt_long_outlined, size: 18)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: row.srp,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => onChanged(),
                  validator: (v) => ValidationUtils.validatePrice(v, fieldName: 'SRP'),
                  decoration: const InputDecoration(labelText: 'SRP (₱)', prefixIcon: Icon(Icons.sell_outlined, size: 18)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: healthy ? AppColors.successBg : AppColors.warningBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(healthy ? Icons.check_circle : Icons.warning_amber_rounded, size: 16, color: healthy ? AppColors.success : AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Margin ${row.margin.toStringAsFixed(1)}% • Profit ₱${(row.srpValue - row.cogsValue).toStringAsFixed(2)}/pack',
                    style: AppTextStyles.labelMd.copyWith(color: healthy ? AppColors.success : AppColors.warning),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
