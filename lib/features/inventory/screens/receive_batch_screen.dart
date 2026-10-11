import 'dart:convert';

import 'package:flutter/material.dart';
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
    _qtyController = TextEditingController(
      text: item != null && item.recommendedRestockQty > 0 ? '${item.recommendedRestockQty}' : '',
    );
    _thresholdController = TextEditingController(text: item == null ? '' : '${item.restockThreshold}');
  }

  @override
  void dispose() {
    _codeController.dispose();
    _qtyController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<void> _pickReceived() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _received,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
    );
    if (picked != null) setState(() => _received = picked);
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now.add(const Duration(days: 90)),
      firstDate: now.add(const Duration(days: 1)),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    if (_expiry == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please choose the expiration date.')));
      return;
    }
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
    } catch (e) {
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
              if (chosen != null) _thresholdController.text = '${chosen.restockThreshold}';
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
            decoration: const InputDecoration(labelText: 'Batch code', hintText: 'e.g. as printed on the supplier slip'),
            validator: (v) => ValidationUtils.validateRequired(v, 'Batch code'),
          ),
          TextFormField(
            controller: _qtyController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantity received (packs)'),
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              if (n == null || n <= 0) return 'Enter a quantity greater than 0';
              if (n > 100000) return 'That quantity is too large';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.md),
          _DateTile(label: 'Received date', value: _fmt(_received), onTap: _pickReceived),
          const SizedBox(height: 10),
          _DateTile(
            label: 'Expiration date',
            value: _expiry == null ? 'Choose a date' : _fmt(_expiry!),
            onTap: _pickExpiry,
            highlight: _expiry == null,
          ),
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: _thresholdController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Restock level (optional)',
              helperText: 'You will be alerted when stock falls to this number or below.',
            ),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) return null;
              final n = int.tryParse(v!.trim());
              if (n == null || n < 0) return 'Enter 0 or more';
              return null;
            },
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

class _DateTile extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool highlight;

  const _DateTile({required this.label, required this.value, required this.onTap, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(color: highlight ? AppColors.warning : AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: AppTextStyles.bodyMd)),
            Text(value, style: AppTextStyles.labelLg),
          ],
        ),
      ),
    );
  }
}
