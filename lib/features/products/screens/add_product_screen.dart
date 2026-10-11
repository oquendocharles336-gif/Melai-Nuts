import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../data/repositories/products_repository.dart';
import '../../../data/repositories/staff_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';

/// "Add New Product" — matches the prototype's multi-section wizard
/// (Media, Basic Info, Pricing & Cost, Variants, Branch Availability),
/// implemented as a single scrollable form. "Save & Publish" creates the
/// product in Supabase through [StaffRepository.saveProduct] (the database
/// checks the caller's permission) and then reloads the catalog.
class AddProductScreen extends StatefulWidget {
  const AddProductScreen({super.key});

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _cogsController = TextEditingController();
  final _srpController = TextEditingController();
  String? _category;
  bool _hasVariants = false;
  final Set<String> _selectedBranchIds = {};
  bool _publishImmediately = true;
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

    if (_selectedBranchIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one branch.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final branchIds = _selectedBranchIds.toList();
      await StaffRepository.instance.saveProduct(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        categoryId: _category,
        price: _srp,
        isActive: _publishImmediately,
        variants: [
          {'label': 'Standard', 'price': _srp, 'cost_price': _cogs > 0 ? _cogs : null},
        ],
        branchIds: branchIds,
      );
      await ProductsRepository.instance.loadCatalog();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${_nameController.text.trim()}" saved.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is AppError ? e.message : 'Could not save the product. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: const Text('Add New Product'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _SectionCard(
                title: '1. Product Media & Images',
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.image_not_supported_outlined, color: AppColors.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Product photos can\'t be uploaded yet. The product will be saved without a photo.',
                          style: AppTextStyles.bodyMd,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _SectionCard(
                title: '2. Basic Information',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppTextField(
                      label: 'Product Name *',
                      controller: _nameController,
                      hint: 'e.g. Honey Glazed Cashew Peanuts',
                      validator: (v) => ValidationUtils.validateMinLength(v, 2, 'Product Name'),
                    ),
                    const SizedBox(height: 14),
                    Text('Category *', style: AppTextStyles.labelLg),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      items: [for (final c in kProductCategories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                      onChanged: (v) => setState(() => _category = v),
                      validator: (v) => ValidationUtils.validateRequired(v, 'Category'),
                    ),
                    const SizedBox(height: 14),
                    AppTextField(label: 'Product Description', controller: _descriptionController, hint: 'Handcrafted, roasted...'),
                  ],
                ),
              ),
              _SectionCard(
                title: '3. Pricing & Cost',
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
                  ],
                ),
              ),
              _SectionCard(
                title: '4. Variants Configuration',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _hasVariants,
                      activeThumbColor: AppColors.primary,
                      title: Text('This product has multiple variants', style: AppTextStyles.labelLg),
                      subtitle: Text('e.g. weights, sizes, flavors', style: AppTextStyles.bodySm),
                      onChanged: (v) => setState(() => _hasVariants = v),
                    ),
                    if (_hasVariants)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Configure variants after saving, from the Manage Variants screen.')),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('Add / Configure Variants'),
                        ),
                      ),
                  ],
                ),
              ),
              _SectionCard(
                title: '5. Branch Availability',
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
                        onChanged: (v) => setState(() {
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
                        'The product starts with 0 stock in each selected branch. Receive a batch to add stock.',
                        style: AppTextStyles.bodySm,
                      ),
                    ),
                    const Divider(height: 20),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _publishImmediately,
                      activeThumbColor: AppColors.primary,
                      title: Text('Publish immediately to POS & Storefront', style: AppTextStyles.labelLg),
                      onChanged: (v) => setState(() => _publishImmediately = v),
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
                    child: PrimaryButton(label: 'Save & Publish Product', loading: _saving, onPressed: _save),
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
