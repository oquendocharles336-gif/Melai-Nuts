import 'package:flutter/material.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/staff_models.dart';
import '../../../data/repositories/staff_repository.dart';

/// Refund requests for this branch — only for staff the owner has allowed to
/// review refunds. The database refuses the list and every action otherwise,
/// so this screen shows nothing for anyone without the permission.
class StaffRefundsScreen extends StatelessWidget {
  const StaffRefundsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        if (!store.canReviewRefunds) {
          return Scaffold(
            backgroundColor: AppColors.canvas,
            appBar: const MelaiAppBar(title: 'Refund Requests', showBack: true),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('You do not have permission to review refunds.', textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
              ),
            ),
          );
        }
        // Loaded lazily: staff without the permission never request it.
        if (!store.refundsState.loaded && !store.refundsState.loading && store.refundsState.error == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => store.refreshRefunds());
        }
        final refunds = store.refunds;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: const MelaiAppBar(title: 'Refund Requests', showBack: true),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshRefunds,
              child: DataStateView(
                isLoading: store.refundsState.busy,
                error: store.refundsState.error,
                isEmpty: refunds.isEmpty,
                onRetry: store.refreshRefunds,
                emptyIcon: Icons.assignment_return_outlined,
                emptyTitle: 'No refund requests.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: refunds.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _RefundCard(refund: refunds[i], store: store),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RefundCard extends StatefulWidget {
  final StaffRefund refund;
  final StaffStore store;

  const _RefundCard({required this.refund, required this.store});

  @override
  State<_RefundCard> createState() => _RefundCardState();
}

class _RefundCardState extends State<_RefundCard> {
  bool _busy = false;

  Future<void> _act(String action, String done) async {
    setState(() => _busy = true);
    try {
      await StaffRepository.instance.reviewRefund(widget.refund.id, action);
      if (!mounted) return;
      widget.store.refreshLive();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendViaHitpay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send refund via HitPay?'),
        content: Text('${peso(widget.refund.amount)} goes back to the customer\'s ${widget.refund.paymentMethod}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final msg = await StaffRepository.instance.sendRefundViaHitpay(widget.refund.id);
      if (!mounted) return;
      widget.store.refreshLive();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _isOnline => !widget.refund.paymentMethod.toLowerCase().contains('cash');

  @override
  Widget build(BuildContext context) {
    final r = widget.refund;
    final buttons = <Widget>[];
    if (!_busy) {
      switch (r.status) {
        case 'pending':
          buttons.addAll([
            Expanded(child: FilledButton(onPressed: () => _act('approve', 'Refund approved.'), child: const Text('Approve'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => _act('reject', 'Refund rejected.'), child: const Text('Reject'))),
          ]);
          break;
        case 'approved':
          if (_isOnline) {
            buttons.addAll([
              Expanded(child: FilledButton(onPressed: _sendViaHitpay, child: const Text('Send via HitPay'))),
              const SizedBox(width: 8),
            ]);
          }
          buttons.add(Expanded(child: OutlinedButton(onPressed: () => _act('process', 'Refund is being processed.'), child: const Text('Start processing'))));
          break;
        case 'processing':
          if (_isOnline) {
            buttons.addAll([
              Expanded(child: FilledButton(onPressed: _sendViaHitpay, child: const Text('Send via HitPay'))),
              const SizedBox(width: 8),
            ]);
          }
          buttons.add(Expanded(child: OutlinedButton(onPressed: () => _act('complete', 'Refund completed.'), child: const Text('Mark refunded'))));
          break;
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
              Expanded(child: Text('${r.id} • ${r.orderId}', style: AppTextStyles.labelLg)),
              Text(r.status.toUpperCase(), style: AppTextStyles.labelSm),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${r.customerName ?? '—'} • ${peso(r.amount)}'
            '${r.isPartial == true && r.orderTotal != null ? ' of ${peso(r.orderTotal!)} (partial)' : ''} via ${r.paymentMethod}',
            style: AppTextStyles.bodyMd,
          ),
          Text(
            'Requested ${friendlyTime(r.createdAt)}${r.completedAt == null ? '' : ' • completed ${friendlyTime(r.completedAt!)}'}',
            style: AppTextStyles.bodySm,
          ),
          if (r.isOpen)
            Text('Not deducted from sales until it is completed.', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          if (r.status == 'completed' && (r.orderRefund?.pointsReversed ?? 0) > 0)
            Text('${r.orderRefund!.pointsReversed} loyalty points reversed', style: AppTextStyles.bodySm),
          if (r.reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Reason: ${r.reason}', style: AppTextStyles.bodySm),
          ],
          if (r.notes.isNotEmpty) Text('Notes: ${r.notes}', style: AppTextStyles.bodySm),
          for (final i in r.items)
            Text('${i.quantity} × ${i.productName}${i.variantLabel.isEmpty ? '' : ' • ${i.variantLabel}'}', style: AppTextStyles.bodySm),
          for (final g in r.returned)
            Text(
              'Received back: ${g.quantity} × ${g.productName} • ${g.condition}${g.restocked ? ' (back in stock)' : ' (not restocked)'}',
              style: AppTextStyles.bodySm.copyWith(color: g.restocked ? AppColors.success : AppColors.textSecondary),
            ),
          if (_busy) ...[const SizedBox(height: 10), const LinearProgressIndicator()],
          if (buttons.isNotEmpty) ...[const SizedBox(height: 10), Row(children: buttons)],
        ],
      ),
    );
  }
}
