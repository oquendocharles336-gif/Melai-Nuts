import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/request_key.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/staff_models.dart';
import '../../../data/repositories/branch_repository.dart';
import '../../../data/repositories/staff_repository.dart';

/// Stock transfers between branches.
///
/// Flow: the branch that needs stock REQUESTS it -> the sending branch SHIPS
/// (its soonest-expiring batches leave its stock) or DECLINES -> the requesting
/// branch RECEIVES it (the batches, with their expiry dates, land in its
/// stock). Stock only moves on ship and receive, and every step is checked by
/// the database.
class StockTransfersScreen extends StatelessWidget {
  const StockTransfersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final transfers = store.transfers;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: const MelaiAppBar(title: 'Stock Transfers', showBack: true),
          floatingActionButton: store.canManageInventory
              ? FloatingActionButton.extended(
                  backgroundColor: AppColors.roleStaff,
                  foregroundColor: Colors.white,
                  onPressed: () => _openRequest(context, store),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Request stock'),
                )
              : null,
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshTransfers,
              child: DataStateView(
                isLoading: store.transfersState.busy,
                error: store.transfersState.error,
                isEmpty: transfers.isEmpty,
                onRetry: store.refreshTransfers,
                emptyIcon: Icons.sync_alt_rounded,
                emptyTitle: 'No transfers yet.',
                emptyMessage: 'Requests to or from this branch will appear here.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
                  itemCount: transfers.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _TransferCard(transfer: transfers[i], store: store),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openRequest(BuildContext context, StaffStore store) async {
    if (kBranches.isEmpty) await BranchRepository.instance.loadBranches();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _RequestSheet(store: store),
    );
  }
}

class _TransferCard extends StatefulWidget {
  final StockTransfer transfer;
  final StaffStore store;

  const _TransferCard({required this.transfer, required this.store});

  @override
  State<_TransferCard> createState() => _TransferCardState();
}

class _TransferCardState extends State<_TransferCard> {
  bool _busy = false;

  Future<void> _act(String action, String doneMessage) async {
    setState(() => _busy = true);
    try {
      await StaffRepository.instance.respondTransfer(widget.transfer.id, action);
      if (!mounted) return;
      widget.store.refreshLive();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(doneMessage)));
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'received':
        return AppColors.success;
      case 'rejected':
      case 'cancelled':
        return AppColors.error;
      case 'in_transit':
        return AppColors.primary;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    final store = widget.store;
    final active = store.activeBranchId;
    final iAmSender = t.fromBranchId == active;
    final iAmReceiver = t.toBranchId == active;
    final canAct = store.canManageInventory;
    final color = _statusColor(t.status);

    final actions = <Widget>[];
    if (canAct && !_busy) {
      if (iAmSender && t.status == 'requested') {
        actions.addAll([
          Expanded(child: FilledButton(onPressed: () => _act('ship', 'Transfer shipped.'), child: const Text('Ship'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => _act('reject', 'Request declined.'), child: const Text('Decline'))),
        ]);
      } else if (iAmReceiver && t.status == 'requested') {
        actions.add(Expanded(child: OutlinedButton(onPressed: () => _act('cancel', 'Request cancelled.'), child: const Text('Cancel request'))));
      } else if (iAmReceiver && t.status == 'in_transit') {
        actions.add(Expanded(child: FilledButton(onPressed: () => _act('receive', 'Stock received.'), child: const Text('Mark as received'))));
      }
    }

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
          Row(
            children: [
              Expanded(child: Text(t.id, style: AppTextStyles.labelLg)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                child: Text(t.statusLabel, style: AppTextStyles.labelSm.copyWith(color: color)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${t.quantity} × ${t.productName}${t.variantLabel.isEmpty ? '' : ' • ${t.variantLabel}'}',
            style: AppTextStyles.bodyMd,
          ),
          const SizedBox(height: 4),
          Text('${t.fromBranchName}  →  ${t.toBranchName}', style: AppTextStyles.bodySm),
          if (t.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Note: ${t.note}', style: AppTextStyles.bodySm),
          ],
          if (t.batches.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Batches: ${t.batches.map((b) => '${b.batchCode} ×${b.quantity}').join(', ')}',
              style: AppTextStyles.bodySm,
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ] else if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: actions),
          ],
        ],
      ),
    );
  }
}

class _RequestSheet extends StatefulWidget {
  final StaffStore store;

  const _RequestSheet({required this.store});

  @override
  State<_RequestSheet> createState() => _RequestSheetState();
}

class _RequestSheetState extends State<_RequestSheet> {
  final _formKey = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _note = TextEditingController();
  String? _fromBranchId;
  String? _variantId;
  bool _saving = false;
  final _requestKey = RequestKeyHolder();

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final toBranch = widget.store.activeBranchId;
    if (toBranch == null) return;
    setState(() => _saving = true);
    try {
      await StaffRepository.instance.requestTransfer(
        fromBranchId: _fromBranchId!,
        toBranchId: toBranch,
        variantId: _variantId!,
        quantity: int.parse(_qty.text.trim()),
        note: _note.text,
        // One key per distinct request: a retry after a timeout reuses it, so
        // the server creates one transfer even if the first try landed.
        idempotencyKey: _requestKey.keyFor(
          jsonEncode([_fromBranchId, toBranch, _variantId, _qty.text.trim(), _note.text.trim()]),
        ),
      );
      if (!mounted) return;
      widget.store.refreshLive();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transfer requested.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.store.activeBranchId;
    final sources = kBranches.where((b) => b.id != active).toList();
    final items = widget.store.inventoryItems;

    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, MediaQuery.of(context).viewInsets.bottom + AppSpacing.md),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Request stock', style: AppTextStyles.headlineSm),
              const SizedBox(height: 4),
              Text('For ${widget.store.activeBranchName}', style: AppTextStyles.bodySm),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: _fromBranchId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Request from branch'),
                items: [for (final b in sources) DropdownMenuItem(value: b.id, child: Text(b.name))],
                onChanged: (v) => setState(() => _fromBranchId = v),
                validator: (v) => v == null ? 'Choose a branch' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _variantId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Product'),
                items: [for (final i in items) DropdownMenuItem(value: i.variantId, child: Text(i.displayName, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _variantId = v),
                validator: (v) => v == null ? 'Choose a product' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _qty,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quantity (packs)'),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return (n == null || n <= 0) ? 'Enter a quantity greater than 0' : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 8),
              PrimaryButton(label: 'Send Request', icon: Icons.send_rounded, loading: _saving, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}
