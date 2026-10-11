import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
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

/// Report a delay for a stop — pick a reason, then continue the route. The
/// delay and its reason are saved on the stop; later stops keep the arrival
/// estimate saved with the run (the server does not recalculate it), and the
/// screen says so instead of predicting new times.
class DelayedDeliveryScreen extends StatefulWidget {
  final Delivery delivery;
  final DeliveryStop stop;

  const DelayedDeliveryScreen({super.key, required this.delivery, required this.stop});

  @override
  State<DelayedDeliveryScreen> createState() => _DelayedDeliveryScreenState();
}

class _DelayedDeliveryScreenState extends State<DelayedDeliveryScreen> {
  final _formKey = GlobalKey<FormState>();
  String _reason = 'Traffic congestion';
  final _noteController = TextEditingController();

  /// Optional details: when given, 5–300 characters and not emoji-only.
  static String? _validateNote(String? v) => ValidationUtils.validateText(v,
      fieldName: 'Details',
      minLength: (v ?? '').trim().isEmpty ? 0 : InputLimits.shortReasonMin,
      maxLength: InputLimits.shortReason);
  bool _submitting = false;

  static const _reasons = [
    'Traffic congestion',
    'Customer unavailable',
    'Incorrect address',
    'Vehicle issue',
    'Weather conditions',
  ];

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !FormUtils.validateAndFocus(_formKey)) return;
    setState(() => _submitting = true);
    final reason = _noteController.text.trim().isEmpty ? _reason : '$_reason — ${_noteController.text.trim()}';

    try {
      final updated = await DeliveryRepository.instance.updateDeliveryStop(
        stopId: widget.stop.id,
        status: 'delayed',
        issueReason: reason,
      );
      StaffStore.instance.applyDelivery(updated);
      if (!mounted) return;

      widget.stop.status = StopStatus.delayed;
      widget.stop.issueReason = reason;
      widget.delivery.status = updated.status;
      setState(() => _submitting = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delay logged for ${widget.stop.customerName}.')),
      );
      Navigator.of(context).pushReplacementNamed(AppRoutes.deliveryNextStop, arguments: widget.delivery);
    } catch (e, st) {
      AppErrors.report(e, st, 'delayed_delivery_screen:submit');
      if (!mounted) return;
      setState(() => _submitting = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final laterStops = widget.delivery.stops.where((s) => s.sequenceIndex > widget.stop.sequenceIndex).toList();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Report Delay', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.warning.withValues(alpha: 0.4))),
              child: Row(
                children: [
                  const Icon(Icons.schedule_rounded, color: AppColors.warning),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Reporting a delay for ${widget.stop.customerName}.', style: AppTextStyles.bodyMd)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Reason for Delay', style: AppTextStyles.headlineSm),
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
                    selectedColor: AppColors.warning.withValues(alpha: 0.2),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Details (optional)', style: AppTextStyles.labelLg),
            const SizedBox(height: 6),
            TextFormField(
              controller: _noteController,
              minLines: 2,
              maxLines: 4,
              maxLength: InputLimits.shortReason,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Add more detail...'),
              validator: _validateNote,
            ),
            if (laterStops.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Stops After This One', style: AppTextStyles.headlineSm),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                child: Column(
                  children: [
                    for (final s in laterStops)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.schedule_rounded, size: 14, color: AppColors.warning),
                            const SizedBox(width: 6),
                            Expanded(child: Text(s.customerName, style: AppTextStyles.bodyMd, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Text(s.eta.isEmpty ? 'No estimate' : 'Saved est. ${s.eta}', style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text('Arrival estimates are not recalculated after a delay; tell the customers if they will be late.', style: AppTextStyles.bodySm),
            ],
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Log Delay & Continue',
              icon: Icons.check_rounded,
              loading: _submitting,
              onPressed: _submit,
            ),
          ],
        ),
        ),
      ),
    );
  }
}
