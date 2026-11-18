import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/widgets/confirm_dialog.dart';
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
import '../../../core/widgets/state_views.dart';
import '../../../data/models/inventory_item.dart';
import '../../staff/staff_offline_sync.dart';

/// Receive stock: records a batch (quantity and expiry date) against a product
/// variant at the branch. With [initialItem] the product is pre-selected (e.g.
/// from the Low Stock screen).
///
/// The batch code is generated automatically and the received date is always
/// today. The expiry date must be 1 to 2 years from today. Saving asks for
/// confirmation first. The database validates everything again (permission,
/// own branch, expiry in the future, unique batch code) and adds the quantity
/// to branch stock.
///
/// Offline the batch is saved on this device as a stock movement ("Pending
/// sync") and sent with the same request key when the connection returns
/// ([StaffOfflineSync]), so it is added once.
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
              : DataStateView(
                  isLoading: store.inventoryState.busy,
                  error: store.inventoryState.error,
                  isEmpty: store.inventoryItems.isEmpty,
                  onRetry: store.refreshInventory,
                  emptyIcon: Icons.inventory_2_outlined,
                  emptyTitle: 'No products to receive stock for.',
                  emptyMessage: 'Add a product under Products first, then come back to Receive Stock.',
                  builder: (context) => _ReceiveForm(store: store, initialItem: initialItem),
                ),
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
  late final TextEditingController _qtyController;
  late final TextEditingController _thresholdController;

  String? _variantId;

  /// Always today: stock is recorded the day it is received.
  final DateTime _received = DateUtils.dateOnly(DateTime.now());

  /// Allowed expiry window: 1 to 2 years after the received date.
  late final DateTime _minExpiry = _addYears(_received, 1);
  late final DateTime _maxExpiry = _addYears(_received, 2);
  late DateTime? _expiry = _minExpiry;

  /// Generated per product chosen, so a retry of the same save reuses it.
  String _batchCode = '';
  bool _assignExisting = false;
  bool _saving = false;
  final _requestKey = RequestKeyHolder();

  InventoryItem? get _item => _variantId == null ? null : widget.store.itemByVariant(_variantId!);

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _variantId = item?.variantId;
    if (item != null) _batchCode = _generateBatchCode(item);
    // Staff type the real quantity received; nothing is pre-filled.
    _qtyController = TextEditingController();
    _thresholdController = TextEditingController(text: item?.restockThreshold?.toString() ?? '');
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _thresholdController.dispose();
    super.dispose();
  }

  static DateTime _addYears(DateTime d, int years) => DateTime(d.year + years, d.month, d.day);

  /// e.g. `CGP-REG-250G-261118-7K3Q`: the product SKU (or "BATCH"), the
  /// received date and 4 random characters. Unique per branch + product on the
  /// server; the random part makes a clash practically impossible.
  static String _generateBatchCode(InventoryItem item) {
    final sku = item.sku.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    final prefix = sku.isEmpty ? 'BATCH' : (sku.length > 20 ? sku.substring(0, 20) : sku);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${two(now.year % 100)}${two(now.month)}${two(now.day)}';
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final suffix = List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
    return '$prefix-$date-$suffix';
  }

  Future<void> _submit() async {
    if (_saving) return;
    // Every field (dates included) shows its own message; first one focused.
    if (!FormUtils.validateAndFocus(_formKey) || _expiry == null) return;
    final branchId = widget.store.activeBranchId;
    final item = _item;
    if (branchId == null || _variantId == null || item == null) return;
    if (_batchCode.isEmpty) _batchCode = _generateBatchCode(item);

    final qty = int.parse(_qtyController.text.trim());
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Are you sure?',
      message: _assignExisting
          ? 'Assign $qty existing unit(s) of ${item.displayName} to batch $_batchCode, '
              'expiring ${DateFormField.formatDate(_expiry!)}?'
          : 'Add $qty pack(s) of ${item.displayName} to ${widget.store.activeBranchName} as batch $_batchCode, '
              'expiring ${DateFormField.formatDate(_expiry!)}?',
      confirmLabel: _assignExisting ? 'Yes, assign' : 'Yes, save',
      cancelLabel: 'Review again',
      destructive: false,
      icon: Icons.inventory_2_outlined,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      final outcome = await StaffOfflineSync.instance.receiveBatch(
        branchId: branchId,
        productId: item.productId,
        variantId: _variantId!,
        batchCode: _batchCode,
        quantity: qty,
        expirationDate: _expiry!,
        receivedDate: _received,
        restockThreshold: int.tryParse(_thresholdController.text.trim()),
        assignExisting: _assignExisting,
        // One key per distinct request: a retry after a timeout reuses it, so the
        // server returns the batch it already created instead of "code already
        // exists" (and never adds the stock twice). Offline it is also the
        // queued operation's id.
        requestKey: _requestKey.keyFor(
          jsonEncode([
            branchId,
            _variantId,
            _batchCode,
            _qtyController.text.trim(),
            _expiry!.toIso8601String(),
            _received.toIso8601String(),
            _thresholdController.text.trim(),
            _assignExisting,
          ]),
        ),
      );
      if (!mounted) return;
      final queued = outcome == SaveOutcome.queued;
      if (!queued) widget.store.refreshLive();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(queued
            ? 'Batch saved on this device (Pending sync). It is sent when the connection returns.'
            : 'Batch saved to inventory.'),
      ));
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
            autovalidateMode: AutovalidateMode.onUserInteraction,
            onChanged: (v) => setState(() {
              _variantId = v;
              _assignExisting = false;
              final chosen = v == null ? null : widget.store.itemByVariant(v);
              _batchCode = chosen == null ? '' : _generateBatchCode(chosen);
              if (chosen != null) _thresholdController.text = chosen.restockThreshold?.toString() ?? '';
            }),
            validator: (v) => v == null ? 'Please choose a product' : null,
          ),
          if (item != null) ...[
            const SizedBox(height: 6),
            Text('Currently ${item.quantity} in stock', style: AppTextStyles.bodySm),
          ],
          const SizedBox(height: AppSpacing.md),
          _ReadOnlyRow(
            icon: Icons.qr_code_2_rounded,
            label: 'Batch code',
            value: _batchCode.isEmpty ? 'Made automatically once you pick a product' : _batchCode,
          ),
          const SizedBox(height: AppSpacing.md),
          TextFormField(
            controller: _qtyController,
            keyboardType: TextInputType.number,
            inputFormatters: InputRules.integer(),
            decoration: const InputDecoration(labelText: 'Quantity received (packs)'),
            validator: (v) => ValidationUtils.validateQuantity(v, fieldName: 'Quantity received', min: 1, max: 99999),
          ),
          const SizedBox(height: AppSpacing.md),
          _ReadOnlyRow(
            icon: Icons.calendar_today_rounded,
            label: 'Received date',
            value: '${DateFormField.formatDate(_received)} (today)',
          ),
          const SizedBox(height: 10),
          DateFormField(
            label: 'Expiration date',
            initialValue: _expiry,
            firstDate: _minExpiry,
            lastDate: _maxExpiry,
            onChanged: (d) => setState(() => _expiry = d),
            // Shelf life of a received batch: 1 to 2 years from today.
            validator: (d) {
              if (d == null) return 'Please choose an expiration date.';
              final day = DateUtils.dateOnly(d);
              if (day.isBefore(_minExpiry) || day.isAfter(_maxExpiry)) {
                return 'Expiration date must be 1 to 2 years from today '
                    '(${DateFormField.formatDate(_minExpiry)} – ${DateFormField.formatDate(_maxExpiry)}).';
              }
              return null;
            },
          ),
          const SizedBox(height: 4),
          Text(
            'Must be between ${DateFormField.formatDate(_minExpiry)} and ${DateFormField.formatDate(_maxExpiry)} (1–2 years).',
            style: AppTextStyles.bodySm,
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

/// A value the staff member cannot edit (made automatically), styled like the
/// form fields around it.
class _ReadOnlyRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ReadOnlyRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Text(label, style: AppTextStyles.bodyMd),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppTextStyles.labelLg,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
