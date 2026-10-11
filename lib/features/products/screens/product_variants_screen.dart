import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/melai_app_bar.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../product_variant_saver.dart';

/// "Manage Variants" — one card per packaging tier with SKU, COGS/SRP,
/// a margin gauge, and stock on hand. Add, edit, duplicate and remove all
/// write to Supabase through `staff_save_product` (the database checks the
/// caller's permission and refuses to delete a variant that has stock or
/// order history) and then reload the shared catalog.
class ProductVariantsScreen extends StatefulWidget {
  final String productId;

  const ProductVariantsScreen({super.key, required this.productId});

  @override
  State<ProductVariantsScreen> createState() => _ProductVariantsScreenState();
}

class _ProductVariantsScreenState extends State<ProductVariantsScreen> {
  bool _busy = false;

  Product? get _product {
    for (final p in kProducts) {
      if (p.id == widget.productId) return p;
    }
    return null;
  }

  Future<void> _apply(Product product, List<Map<String, dynamic>> variants, String okMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await saveProductVariants(product, variants);
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(okMessage)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
        content: Text(e is AppError ? e.message : 'Could not save the variants. Please try again.'),
      ));
    }
  }

  Future<void> _add(Product product, {ProductVariant? template}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VariantFormDialog(variant: template),
    );
    if (result == null || !mounted) return;
    await _apply(
      product,
      [for (final v in product.variants) variantToPayload(v), result],
      'Variant added.',
    );
  }

  Future<void> _edit(Product product, ProductVariant variant) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VariantFormDialog(variant: variant),
    );
    if (result == null || !mounted) return;
    await _apply(
      product,
      [for (final v in product.variants) v.id == variant.id ? result : variantToPayload(v)],
      'Variant updated.',
    );
  }

  /// Opens the add form pre-filled from [variant]; nothing is saved until the
  /// form is submitted, and the copy gets its own id from the database.
  Future<void> _duplicate(Product product, ProductVariant variant) => _add(
        product,
        template: ProductVariant(
          label: '${variant.label} copy',
          price: variant.price,
          costPrice: variant.costPrice,
        ),
      );

  Future<void> _remove(Product product, ProductVariant variant) async {
    if (product.variants.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A product needs at least one variant.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${variant.label}"?'),
        content: const Text(
          'A variant that has stock or order history cannot be removed. '
          'In that case, deactivate the product instead.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _apply(
      product,
      [for (final v in product.variants) if (v.id != variant.id) variantToPayload(v)],
      'Variant removed.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    if (product == null) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: const MelaiAppBar(title: 'Manage Variants', showBack: true),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'This product could not be found. It may have been deactivated or removed.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
            ),
          ),
        ),
      );
    }

    final combinedStock = product.variants.fold<int>(0, (sum, v) => sum + (v.stockOnHand ?? 0));
    final averageMargin = product.variants.isEmpty
        ? 0.0
        : product.variants.map((v) => v.marginPercent).reduce((a, b) => a + b) / product.variants.length;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Manage Variants',
        showBack: true,
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : () => _add(product),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('Add Variant'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
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
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                        child: Icon(product.icon, color: product.color),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(product.name, style: AppTextStyles.titleMd),
                            Text(
                              'Base SKU: ${product.sku.isEmpty ? '—' : product.sku} • ${product.variants.length} variant${product.variants.length == 1 ? '' : 's'}',
                              style: AppTextStyles.bodySm,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _SummaryStat(label: 'Combined Stock', value: '$combinedStock packs'),
                      ),
                      Expanded(
                        child: _SummaryStat(label: 'Average Margin', value: '${averageMargin.toStringAsFixed(1)}%', valueColor: AppColors.success),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            for (final variant in product.variants)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _VariantCard(
                  variant: variant,
                  busy: _busy,
                  onEdit: () => _edit(product, variant),
                  onDuplicate: () => _duplicate(product, variant),
                  onRemove: () => _remove(product, variant),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _add(product),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add Custom Variant (e.g. 1kg Catering Bag)'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add / edit form for one variant. Returns the `staff_save_product` variant
/// payload (with the id when editing) or null when cancelled.
class _VariantFormDialog extends StatefulWidget {
  final ProductVariant? variant;

  const _VariantFormDialog({this.variant});

  @override
  State<_VariantFormDialog> createState() => _VariantFormDialogState();
}

class _VariantFormDialogState extends State<_VariantFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.variant?.label ?? '');
  late final _price = TextEditingController(
    text: widget.variant == null ? '' : widget.variant!.price.toStringAsFixed(2),
  );
  late final _cost = TextEditingController(
    text: widget.variant?.costPrice == null ? '' : widget.variant!.costPrice!.toStringAsFixed(2),
  );
  late final _sku = TextEditingController(text: widget.variant?.sku ?? '');
  late final _badge = TextEditingController(text: widget.variant?.badge ?? '');

  bool get _isEdit => (widget.variant?.id ?? '').isNotEmpty;

  @override
  void dispose() {
    _label.dispose();
    _price.dispose();
    _cost.dispose();
    _sku.dispose();
    _badge.dispose();
    super.dispose();
  }

  String? _orNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final cost = double.tryParse(_cost.text.trim());
    Navigator.of(context).pop(<String, dynamic>{
      if (_isEdit) 'id': widget.variant!.id,
      'label': _label.text.trim(),
      'price': double.parse(_price.text.trim()),
      'cost_price': (cost != null && cost > 0) ? cost : null,
      'sku': _orNull(_sku),
      'badge': _orNull(_badge),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit variant' : 'New variant'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTextField(
                label: 'Label *',
                controller: _label,
                hint: 'e.g. 250g pouch',
                validator: (v) => ValidationUtils.validateRequired(v, 'Label'),
              ),
              const SizedBox(height: 12),
              AppTextField(
                label: 'Retail price (SRP) *',
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) => ValidationUtils.validatePrice(v, fieldName: 'Price'),
              ),
              const SizedBox(height: 12),
              AppTextField(
                label: 'Cost of goods (COGS)',
                controller: _cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) => ValidationUtils.validateNumber(v, fieldName: 'Cost', min: 0, allowEmpty: true),
              ),
              const SizedBox(height: 12),
              AppTextField(label: 'SKU', controller: _sku),
              const SizedBox(height: 12),
              AppTextField(label: 'Badge', controller: _badge, hint: 'e.g. Best Value'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _SummaryStat({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.bodySm),
        Text(value, style: AppTextStyles.titleMd.copyWith(color: valueColor)),
      ],
    );
  }
}

class _VariantCard extends StatelessWidget {
  final ProductVariant variant;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onRemove;

  const _VariantCard({
    required this.variant,
    required this.busy,
    required this.onEdit,
    required this.onDuplicate,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final healthy = variant.marginPercent >= 55;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: variant.badge != null ? AppColors.primary : AppColors.border, width: variant.badge != null ? 1.4 : 1),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(variant.label, style: AppTextStyles.titleMd)),
              if (variant.badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(20)),
                  child: Text(variant.badge!, style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
                ),
            ],
          ),
          Text('SKU: ${variant.sku ?? '—'}', style: AppTextStyles.bodySm),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onDuplicate,
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  label: const Text('Duplicate'),
                ),
              ),
              IconButton(
                onPressed: busy ? null : onRemove,
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('COGS: ₱${(variant.costPrice ?? 0).toStringAsFixed(2)}', style: AppTextStyles.bodySm),
              Text('SRP: ₱${variant.price.toStringAsFixed(2)}', style: AppTextStyles.labelLg.copyWith(color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Margin Gauge', style: AppTextStyles.bodySm),
              Text(
                '${variant.marginPercent.toStringAsFixed(1)}% ${healthy ? 'Healthy' : 'Review'}',
                style: AppTextStyles.labelSm.copyWith(color: healthy ? AppColors.success : AppColors.warning),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (variant.marginPercent / 100).clamp(0, 1),
              minHeight: 6,
              backgroundColor: AppColors.border,
              color: healthy ? AppColors.success : AppColors.warning,
            ),
          ),
          const SizedBox(height: 6),
          Text('Net Profit: ₱${variant.netProfit.toStringAsFixed(2)} / pack', style: AppTextStyles.bodySm),
          if (variant.stockOnHand != null) ...[
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Stock on Hand', style: AppTextStyles.bodySm),
                Text('${variant.stockOnHand} packs', style: AppTextStyles.labelLg),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
