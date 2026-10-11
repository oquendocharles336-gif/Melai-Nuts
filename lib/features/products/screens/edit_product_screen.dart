import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../data/repositories/products_repository.dart';
import '../../../data/repositories/staff_repository.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';

/// "Edit Product" — same section layout as [AddProductScreen], pre-filled
/// with the selected product's current data. "Save Changes"
/// writes to Supabase through [StaffRepository.saveProduct].
class EditProductScreen extends StatefulWidget {
  final String productId;

  const EditProductScreen({super.key, required this.productId});

  @override
  State<EditProductScreen> createState() => _EditProductScreenState();
}

class _EditProductScreenState extends State<EditProductScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Product _product = findProductById(widget.productId);
  late final _nameController = TextEditingController(text: _product.name);
  late final _descriptionController = TextEditingController(text: _product.description);
  late final _cogsController = TextEditingController(text: _product.costPrice.toStringAsFixed(2));
  late final _srpController = TextEditingController(text: _product.price.toStringAsFixed(2));
  late String _category = _product.categoryId;
  late bool _isActive = _product.isActive;
  // Branches that already stock this product. The database only ever ADDS
  // branch availability from this form (it never removes it), so these stay
  // ticked and locked; stock leaves a branch through Inventory instead.
  late final Set<String> _stockedBranchIds = {
    for (final b in kBranches)
      if (_product.branchAvailability.contains(b.name)) b.id,
  };
  late final Set<String> _selectedBranchIds = {..._stockedBranchIds};
  bool _saving = false;

  double get _cogs => double.tryParse(_cogsController.text) ?? 0;
  double get _srp => double.tryParse(_srpController.text) ?? 0;
  double get _margin => _srp == 0 ? 0 : ((_srp - _cogs) / _srp) * 100;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _cogsController.dispose();
    _srpController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final branchIds = _selectedBranchIds.toList();
      // A single-variant product follows the edited price; multi-variant
      // products keep their variants (managed on the variants screen).
      final variants = _product.variants.length <= 1
          ? [
              {
                if (_product.variants.isNotEmpty) 'id': _product.variants.first.id,
                'label': _product.variants.isNotEmpty ? _product.variants.first.label : 'Standard',
                'price': _srp,
                'cost_price': _cogs > 0 ? _cogs : null,
                'sku': _product.variants.isNotEmpty ? _product.variants.first.sku : null,
                'badge': _product.variants.isNotEmpty ? _product.variants.first.badge : null,
              },
            ]
          : _product.variants
              .map((v) => {'id': v.id, 'label': v.label, 'price': v.price, 'cost_price': v.costPrice, 'sku': v.sku, 'badge': v.badge})
              .toList();
      await StaffRepository.instance.saveProduct(
        productId: _product.id,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        categoryId: _category.isEmpty ? null : _category,
        price: _srp,
        sku: _product.sku,
        images: _product.images,
        isActive: _isActive,
        isFeatured: _product.isFeatured,
        variants: variants,
        branchIds: branchIds,
      );
      await ProductsRepository.instance.loadCatalog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${_nameController.text.trim()}" changes saved.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is AppError ? e.message : 'Could not save changes. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Never edit a placeholder: if the product isn't in the loaded catalog
    // (not found, or no longer active) say so instead of showing a form that
    // would save over a different record.
    if (!kProducts.any((p) => p.id == widget.productId)) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: AppBar(title: const Text('Edit Product')),
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

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: const Text('Edit Product'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _SectionCard(
                title: 'Product Media & Images',
                child: Row(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(color: _product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                      child: Icon(_product.icon, color: _product.color, size: 32),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Product photos can\'t be changed yet. Existing photos are kept as they are.',
                        style: AppTextStyles.bodyMd,
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Basic Information',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppTextField(
                      label: 'Product Name *',
                      controller: _nameController,
                      validator: (v) => ValidationUtils.validateMinLength(v, 2, 'Product Name'),
                    ),
                    const SizedBox(height: 14),
                    Text('Category *', style: AppTextStyles.labelLg),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      items: [for (final c in kProductCategories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                      onChanged: (v) => setState(() => _category = v ?? _category),
                      validator: (v) => ValidationUtils.validateRequired(v, 'Category'),
                    ),
                    const SizedBox(height: 14),
                    AppTextField(label: 'Product Description', controller: _descriptionController),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _isActive,
                      activeThumbColor: AppColors.primary,
                      title: Text('Active in catalog & POS', style: AppTextStyles.labelLg),
                      onChanged: (v) => setState(() => _isActive = v),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Pricing & Cost',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AppTextField(
                            label: 'Cost of Goods (COGS)',
                            controller: _cogsController,
                            prefixIcon: Icons.receipt_long_outlined,
                            keyboardType: TextInputType.number,
                            validator: (v) => ValidationUtils.validateNumber(v, fieldName: 'COGS', min: 0, allowEmpty: true),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: AppTextField(
                            label: 'Base Retail Price (SRP) *',
                            controller: _srpController,
                            prefixIcon: Icons.sell_outlined,
                            keyboardType: TextInputType.number,
                            validator: (v) => ValidationUtils.validatePrice(v, fieldName: 'Retail Price'),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _margin >= 50 ? AppColors.successBg : AppColors.warningBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(_margin >= 50 ? Icons.check_circle : Icons.info_outline_rounded,
                              size: 18, color: _margin >= 50 ? AppColors.success : AppColors.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Margin: ${_margin.toStringAsFixed(1)}% (₱${(_srp - _cogs).toStringAsFixed(2)} profit/unit)',
                              style: AppTextStyles.labelMd.copyWith(color: _margin >= 50 ? AppColors.success : AppColors.warning),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pushNamed(AppRoutes.productVariants, arguments: _product.id),
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('Manage Variants & Per-Variant Pricing'),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Branch Availability',
                child: Column(
                  children: [
                    if (kBranches.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('Branches have not loaded yet. Go back and try again.', style: AppTextStyles.bodyMd),
                      ),
                    for (final branch in kBranches)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _selectedBranchIds.contains(branch.id),
                        activeColor: AppColors.primary,
                        title: Text(branch.name, style: AppTextStyles.bodyMd),
                        subtitle: _stockedBranchIds.contains(branch.id)
                            ? Text('Currently stocked', style: AppTextStyles.bodySm)
                            : null,
                        onChanged: _stockedBranchIds.contains(branch.id)
                            ? null
                            : (v) => setState(() {
                                  if (v == true) {
                                    _selectedBranchIds.add(branch.id);
                                  } else {
                                    _selectedBranchIds.remove(branch.id);
                                  }
                                }),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Ticking a branch makes the product available there with 0 stock. Branches that already stock it can\'t be removed here.',
                        style: AppTextStyles.bodySm,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(child: SecondaryButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: PrimaryButton(label: 'Save Changes', loading: _saving, onPressed: _save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTextStyles.titleMd),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
