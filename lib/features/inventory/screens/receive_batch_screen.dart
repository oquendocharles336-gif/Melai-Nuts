import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/widgets/date_form_field.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/request_key.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/models/inventory_item.dart';
import '../../../data/repositories/staff_repository.dart';

/// Receive stock: records a batch (code, quantity, received / expiry dates)
/// against a product variant at the branch. With [initialItem] the product is
/// pre-selected (e.g. from the Low Stock screen).
///
/// The database validates everything again (permission, own branch, expiry in
/// the future, unique batch code) and adds the quantity to branch stock.
class ReceiveBatchScreen extends StatelessWidget {
  final InventoryItem? initialItem;

  const ReceiveBatchScreen({super.key, this.initialItem});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) => Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: const MelaiAppBar(title: 'Receive Stock', showBack: true),
        body: SafeArea(
          child: !store.canManageInventory
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      'You do not have permission to manage inventory.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyMd,
                    ),
                  ),
                )
              : _ReceiveForm(store: store, initialItem: initialItem),
        ),
      ),
    );
  }
}

class _ReceiveForm extends StatefulWidget {
  final StaffStore store;
  final InventoryItem? initialItem;

  const _ReceiveForm({required this.store, required this.initialItem});

  @override
  State<_ReceiveForm> createState() => _ReceiveFormState();
}

class _ReceiveFormState extends State<_ReceiveForm> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  late final TextEditingController _qtyController;
  late final TextEditingController _thresholdController;

  String? _variantId;
  DateTime _received = DateTime.now();
  DateTime? _expiry;
  bool _assignExisting = false;
  bool _saving = false;
  final _requestKey = RequestKeyHolder();

  InventoryItem? get _item => _variantId == null ? null : widget.store.itemByVariant(_variantId!);

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _variantId = item?.variantId;
    // Staff type the real quantity received; nothing is pre-filled.
    _qtyController = TextEditingController();
    _thresholdController = TextEditingController(text: item?.restockThreshold?.toString() ?? '');
  }

  @override
  void dispose() {
    _codeController.dispose();
    _qtyController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    // Every field (dates included) shows its own message; first one focused.
    if (!FormUtils.validateAndFocus(_formKey) || _expiry == null) return;
    final branchId = widget.store.activeBranchId;
    if (branchId == null || _variantId == null) return;

    setState(() => _saving = true);
    try {
      await StaffRepository.instance.receiveBatch(
        branchId: branchId,
        variantId: _variantId!,
        batchCode: _codeController.text.trim(),
        quantity: int.parse(_qtyController.text.trim()),
        expirationDate: _expiry!,
        receivedDate: _received,
        restockThreshold: int.tryParse(_thresholdController.text.trim()),
        assignExisting: _assignExisting,
        // One key per distinct request: a retry after a timeout reuses it, so the
        // server returns the batch it already created instead of "code already
        // exists" (and never adds the stock twice).
        idempotencyKey: _requestKey.keyFor(
          jsonEncode([
            branchId,
            _variantId,
            _codeController.text.trim(),
            _qtyController.text.trim(),
            _expiry!.toIso8601String(),
            _received.toIso8601String(),
            _thresholdController.text.trim(),
            _assignExisting,
          ]),
        ),
      );
      if (!mounted) return;
      widget.store.refreshLive();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Batch saved to inventory.')));
      Navigator.of(context).pop();
    } catch (e, st) {
      // The form keeps its values; the same request key makes a retry safe.
      AppErrors.report(e, st, 'receive_batch_screen:submit');
      if (!mounted) return;
      setState(() => _saving = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.store.inventoryItems;
    final item = _item;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Text('Receiving into ${widget.store.activeBranchName}', style: AppTextStyles.bodyMd),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String>(
            initialValue: _variantId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Product'),
            items: [
              for (final i in items) DropdownMenuItem(value: i.variantId, child: Text(i.displayName, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              _variantId = v;
              _assignExisting = false;
              final chosen = v == null ? null : widget.store.itemByVariant(v);
              if (chosen != null) _thresholdController.text = chosen.restockThreshold?.toString() ?? '';
            }),
            validator: (v) => v == null ? 'Please choose a product' : null,
          ),
          if (item != null) ...[
            const SizedBox(height: 6),
            Text('Currently ${item.quantity} in stock', style: AppTextStyles.bodySm),
          ],
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            maxLength: 40,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            decoration: const InputDecoration(labelText: 'Batch code', hintText: 'e.g. as printed on the supplier slip'),
            validator: (v) => ValidationUtils.validateText(v, fieldName: 'Batch code', required: true, maxLength: 40),
          ),
          TextFormField(
            controller: _qtyController,
            keyboardType: TextInputType.number,
            inputFormatters: InputRules.integer(),
            decoration: const InputDecoration(labelText: 'Quantity received (packs)'),
            validator: (v) => ValidationUtils.validateQuantity(v, fieldName: 'Quantity received', min: 1, max: 99999),
          ),
          const SizedBox(height: AppSpacing.md),
          DateFormField(
            label: 'Received date',
            initialValue: _received,
            firstDate: DateTime(DateTime.now().year - 1),
            lastDate: DateTime.now(),
            onChanged: (d) => setState(() => _received = d),
            // Received today or earlier — never in the future.
            validator: (d) => ValidationUtils.validateDateValue(d, fieldName: 'Received date', allowFuture: false),
          ),
          const SizedBox(height: 10),
          DateFormField(
            label: 'Expiration date',
            initialValue: _expiry,
            firstDate: DateTime.now().add(const Duration(days: 1)),
            lastDate: DateTime(DateTime.now().year + 5),
            onChanged: (d) => setState(() => _expiry = d),
            // Stock being received cannot already be expired, nor expire before it
            // arrived. Same rule as staff_receive_batch: strictly after today.
            validator: (d) => d != null && !DateUtils.dateOnly(d).isAfter(DateUtils.dateOnly(DateTime.now()))
                ? 'Expiration date must be after today.'
                : ValidationUtils.validateDateValue(
              d,
              fieldName: 'Expiration date',
              allowPast: false,
              notBefore: _received,
              notBeforeLabel: 'the received date',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: _thresholdController,
            keyboardType: TextInputType.number,
            inputFormatters: InputRules.integer(),
            decoration: const InputDecoration(
              labelText: 'Restock level (optional)',
              helperText: 'You will be alerted when stock falls to this number or below.',
            ),
            validator: (v) => (v ?? '').trim().isEmpty
                ? null
                : ValidationUtils.validateQuantity(v, fieldName: 'Restock level', min: 0, max: 99999),
          ),
          if (item != null && item.unassignedQuantity > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _assignExisting,
              activeThumbColor: AppColors.primary,
              title: Text('Units already counted in stock', style: AppTextStyles.labelLg),
              subtitle: Text(
                '${item.unassignedQuantity} unit(s) have no batch yet. Turn this on to give them this batch '
                'instead of adding new stock.',
                style: AppTextStyles.bodySm,
              ),
              onChanged: (v) => setState(() => _assignExisting = v),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          PrimaryButton(
            label: _assignExisting ? 'Assign to Batch' : 'Save Batch to Inventory',
            icon: Icons.cloud_upload_outlined,
            loading: _saving,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
