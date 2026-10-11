import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/delivery.dart';
import '../../../data/repositories/delivery_repository.dart';

/// Staff-side delivery confirmation: an optional note describing the hand-over,
/// then the stop is marked delivered in the database. Photo proof and the
/// recipient's name are captured by the registered driver in the Melai Nuts
/// driver app (`driver_update_stop`); this screen does not pretend to capture
/// a signature or photo.
class DeliveryConfirmationScreen extends StatefulWidget {
  final Delivery delivery;
  final DeliveryStop stop;

  const DeliveryConfirmationScreen({super.key, required this.delivery, required this.stop});

  @override
  State<DeliveryConfirmationScreen> createState() => _DeliveryConfirmationScreenState();
}

class _DeliveryConfirmationScreenState extends State<DeliveryConfirmationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _noteController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_submitting || !FormUtils.validateAndFocus(_formKey)) return;
    final ok = await ConfirmDialog.show(
      context,
      title: 'Confirm delivery?',
      message: 'Order ${widget.stop.orderId} for ${widget.stop.customerName} will be marked as delivered.',
      confirmLabel: 'Confirm',
      destructive: false,
      icon: Icons.check_circle_outline_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _submitting = true);
    final note = _noteController.text.trim().isEmpty ? null : _noteController.text.trim();

    try {
      final updated = await DeliveryRepository.instance.updateDeliveryStop(
        stopId: widget.stop.id,
        status: 'delivered',
        proofNote: note,
      );
      StaffStore.instance.applyDelivery(updated);
      if (!mounted) return;

      widget.stop.status = StopStatus.delivered;
      widget.stop.proofNote = note;
      widget.delivery.status = updated.status;
      setState(() => _submitting = false);

      final nextStop = widget.delivery.stops.any((s) => s.status == StopStatus.pending || s.status == StopStatus.enRoute);
      if (nextStop) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.deliveryNextStop, arguments: widget.delivery);
      } else {
        Navigator.of(context).pushReplacementNamed(AppRoutes.deliveryCompleted, arguments: widget.delivery);
      }
    } catch (e, st) {
      AppErrors.report(e, st, 'delivery_confirmation_screen:confirm');
      if (!mounted) return;
      setState(() => _submitting = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Confirm Delivery', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                    child: const Icon(Icons.person, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.stop.customerName, style: AppTextStyles.labelLg),
                        Text(widget.stop.orderId, style: AppTextStyles.bodySm),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Delivery Note (optional)', style: AppTextStyles.labelLg),
            const SizedBox(height: 6),
            TextFormField(
              controller: _noteController,
              minLines: 2,
              maxLines: 4,
              maxLength: InputLimits.note,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'e.g. Left with guard, gate code confirmed...'),
              validator: (v) => ValidationUtils.validateText(v, fieldName: 'Delivery note'),
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(AppSpacing.radiusMd)),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Photo proof and the recipient\'s name are recorded by the driver in the Melai Nuts driver app. Here you can only add a note.',
                      style: AppTextStyles.bodySm,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Confirm Delivery',
              icon: Icons.check_circle_outline_rounded,
              loading: _submitting,
              onPressed: _confirm,
            ),
          ],
        ),
        ),
      ),
    );
  }
}
