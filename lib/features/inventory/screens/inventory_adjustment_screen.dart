import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/request_key.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/repositories/staff_repository.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/inventory_batch.dart';

/// Stock adjustment for one batch (damage, count correction, ...).
///
/// The change is saved by the database, which re-checks that the caller may
/// manage inventory at this branch and that stock cannot go below zero. The
/// success screen is only shown once the database has confirmed the change.
class InventoryAdjustmentScreen extends StatefulWidget {
  final InventoryBatch batch;

  const InventoryAdjustmentScreen({super.key, required this.batch});

  @override
  State<InventoryAdjustmentScreen> createState() => _InventoryAdjustmentScreenState();
}

class _InventoryAdjustmentScreenState extends State<InventoryAdjustmentScreen> {
  final _formKey = GlobalKey<FormState>();
  int _adjustment = 0;
  bool _saving = false;
  final _reasonController = TextEditingController();
  final _amountController = TextEditingController(text: '0');
  String _reasonPreset = 'Stock count correction';
  final _requestKey = RequestKeyHolder();

  int get _rawNewStock => widget.batch.quantity + _adjustment;
  int get _newStock => _rawNewStock.clamp(0, 999999);

  @override
  void dispose() {
    _reasonController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _step(int by) {
    setState(() => _adjustment += by);
    _amountController.text = '$_adjustment';
  }

  /// Adjustment amount: a whole number (negative to remove stock), not 0,
  /// at most 99,999 either way, and stock may not go below 0.
  String? _validateAmount(String? v) {
    final raw = (v ?? '').trim();
    final n = int.tryParse(raw);
    if (raw.isEmpty || raw == '-') return 'Enter how many packs to add or remove.';
    if (n == null) return 'Adjustment must be a whole number.';
    if (n == 0) return 'Adjustment cannot be 0.';
    final sizeError = ValidationUtils.validateQuantity('${n.abs()}', fieldName: 'Adjustment', min: 1, max: 99999);
    if (sizeError != null) return sizeError;
    if (widget.batch.quantity + n < 0) {
      return 'Stock cannot go below 0 (only ${widget.batch.quantity} in this batch).';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_saving || !FormUtils.validateAndFocus(_formKey)) return;
    // Stock changes are recorded in the audit log: confirm first.
    final ok = await ConfirmDialog.show(
      context,
      title: 'Save this adjustment?',
      message: '${_adjustment > 0 ? 'Add' : 'Remove'} ${_adjustment.abs()} pack(s) '
          '${_adjustment > 0 ? 'to' : 'from'} batch ${widget.batch.batchCode} '
          '(${widget.batch.quantity} → $_newStock). Reason: $_reasonPreset.',
      confirmLabel: 'Save',
      destructive: _adjustment < 0,
      icon: Icons.inventory_2_outlined,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final result = await StaffRepository.instance.adjustBatch(
        batchId: widget.batch.id,
        delta: _adjustment,
        reason: _reasonPreset,
        note: _reasonController.text.trim(),
        // One key per distinct request: a retry after a timeout reuses it, so
        // the server applies the adjustment once even if the first try landed.
        idempotencyKey: _requestKey.keyFor(
          jsonEncode([widget.batch.id, _adjustment, _reasonPreset, _reasonController.text.trim()]),
        ),
      );
      if (!mounted) return;
      StaffStore.instance.refreshLive();
      Navigator.of(context).pushReplacementNamed(
        AppRoutes.inventoryAdjustmentSuccess,
        arguments: {
          'productId': widget.batch.productId,
          'batch': widget.batch,
          'adjustment': (result['adjustment'] as num).toInt(),
          'newStock': (result['new_quantity'] as num).toInt(),
        },
      );
    } catch (e, st) {
      AppErrors.report(e, st, 'inventory_adjustment_screen:submit');
      if (!mounted) return;
      setState(() => _saving = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = findProductById(widget.batch.productId);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Adjust Inventory', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: product.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                      child: Icon(product.icon, color: product.color),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(product.name, style: AppTextStyles.labelLg),
                          Text('${widget.batch.variantLabel.isEmpty ? '' : '${widget.batch.variantLabel} • '}Batch ${widget.batch.batchCode} • ${widget.batch.branch}', style: AppTextStyles.bodySm),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _StockNumber(label: 'Batch Stock', value: '${widget.batch.quantity}'),
                        const Icon(Icons.arrow_forward_rounded, color: AppColors.textSecondary),
                        _StockNumber(
                          label: 'Adjustment',
                          value: '${_adjustment >= 0 ? '+' : ''}$_adjustment',
                          valueColor: _adjustment >= 0 ? AppColors.success : AppColors.error,
                        ),
                        const Icon(Icons.arrow_forward_rounded, color: AppColors.textSecondary),
                        _StockNumber(label: 'New Stock', value: '$_newStock', valueColor: AppColors.roleStaff),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filled(
                          tooltip: 'Remove 5 packs',
                          onPressed: () => _step(-5),
                          icon: const Icon(Icons.remove_rounded),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 120,
                          child: TextFormField(
                            controller: _amountController,
                            textAlign: TextAlign.center,
                            style: AppTextStyles.headlineMd,
                            keyboardType: const TextInputType.numberWithOptions(signed: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,5}')),
                            ],
                            decoration: const InputDecoration(labelText: 'Packs (+/-)'),
                            onChanged: (v) => setState(() => _adjustment = int.tryParse(v.trim()) ?? 0),
                            validator: _validateAmount,
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filled(
                          tooltip: 'Add 5 packs',
                          onPressed: () => _step(5),
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                    Text('Type the exact number (negative removes stock), or tap +/- to change it by 5.',
                        style: AppTextStyles.bodySm, textAlign: TextAlign.center),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Reason for Adjustment', style: AppTextStyles.labelLg),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final reason in const ['Stock count correction', 'Damaged goods', 'Expired / disposed', 'Found extra stock'])
                    ChoiceChip(
                      label: Text(reason),
                      selected: _reasonPreset == reason,
                      onSelected: (_) => setState(() => _reasonPreset = reason),
                      selectedColor: AppColors.roleStaff.withValues(alpha: 0.15),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(hintText: 'Optional notes...'),
                minLines: 1,
                maxLines: 3,
                maxLength: 200,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                textCapitalization: TextCapitalization.sentences,
                validator: (v) => ValidationUtils.validateText(v, fieldName: 'Notes', maxLength: 200),
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Submit Adjustment',
                icon: Icons.check_rounded,
                loading: _saving,
                // Always enabled: problems are explained under the field instead.
                onPressed: _submit,
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
