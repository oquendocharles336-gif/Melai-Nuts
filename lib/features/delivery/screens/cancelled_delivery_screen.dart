import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/delivery.dart';
import '../../../data/repositories/delivery_repository.dart';

/// Cancel a stop — pick a reason and confirm. The stop is marked
/// cancelled/skipped and the rider continues to the next stop.
class CancelledDeliveryScreen extends StatefulWidget {
  final Delivery delivery;
  final DeliveryStop stop;

  const CancelledDeliveryScreen({super.key, required this.delivery, required this.stop});

  @override
  State<CancelledDeliveryScreen> createState() => _CancelledDeliveryScreenState();
}

class _CancelledDeliveryScreenState extends State<CancelledDeliveryScreen> {
  String _reason = 'Customer not available';
  final _noteController = TextEditingController();
  bool _submitting = false;

  static const _reasons = [
    'Customer not available',
    'Customer refused delivery',
    'Address not found',
    'Damaged / lost package',
    'Other',
  ];

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this stop?'),
        content: Text('${widget.stop.customerName} will be marked as cancelled for this route.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Back')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm Cancel')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _submitting = true);
    final reason = _noteController.text.trim().isEmpty ? _reason : '$_reason — ${_noteController.text.trim()}';

    try {
      final updated = await DeliveryRepository.instance.updateDeliveryStop(
        stopId: widget.stop.id,
        status: 'skipped',
        issueReason: reason,
      );
      StaffStore.instance.applyDelivery(updated);
      if (!mounted) return;

      widget.stop.status = StopStatus.skipped;
      widget.stop.issueReason = reason;
      widget.delivery.status = updated.status;
      setState(() => _submitting = false);

      final stillPending = widget.delivery.stops.any((s) => s.status == StopStatus.pending || s.status == StopStatus.enRoute);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stop for ${widget.stop.customerName} cancelled.')),
      );

      if (stillPending) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.deliveryNextStop, arguments: widget.delivery);
      } else {
        Navigator.of(context).pushReplacementNamed(AppRoutes.deliveryCompleted, arguments: widget.delivery);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Cancel Stop', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.errorBg, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.error.withValues(alpha: 0.3))),
              child: Row(
                children: [
                  const Icon(Icons.cancel_outlined, color: AppColors.error),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Cancelling delivery to ${widget.stop.customerName} (${widget.stop.orderId}).', style: AppTextStyles.bodyMd)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Reason for Cancellation', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in _reasons)
                  ChoiceChip(
                    label: Text(r),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                    selectedColor: AppColors.error.withValues(alpha: 0.15),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Additional Notes (optional)', style: AppTextStyles.labelLg),
            const SizedBox(height: 6),
            TextField(controller: _noteController, maxLines: 2, decoration: const InputDecoration(hintText: 'Add more detail...')),
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(AppSpacing.radiusMd)),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(child: Text('This updates the delivery record — no customer notification is sent.', style: AppTextStyles.bodySm)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SecondaryButton(
              label: 'Confirm Cancellation',
              icon: Icons.cancel_outlined,
              onPressed: _submitting ? null : _confirmCancel,
            ),
          ],
        ),
      ),
    );
  }
}
