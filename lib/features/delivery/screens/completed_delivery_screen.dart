import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/delivery.dart';

/// Shown once every stop in a delivery has been handled — a summary of
/// the whole run (distance, time, delivered/delayed/cancelled counts).
class CompletedDeliveryScreen extends StatelessWidget {
  final Delivery delivery;

  const CompletedDeliveryScreen({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final delivered = delivery.stops.where((s) => s.status == StopStatus.delivered).length;
    final delayed = delivery.stops.where((s) => s.status == StopStatus.delayed).length;
    final cancelled = delivery.stops.where((s) => s.status == StopStatus.skipped).length;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: const BoxDecoration(color: AppColors.successBg, shape: BoxShape.circle),
                child: const Icon(Icons.celebration_rounded, color: AppColors.success, size: 44),
              ),
            ),
            const SizedBox(height: 16),
            Text('Route Completed!', textAlign: TextAlign.center, style: AppTextStyles.headlineLg),
            const SizedBox(height: 6),
            Text(
              'Great work — ${delivery.id} is finished. Summary below.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMd,
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _Stat(label: 'Total Distance', value: '${delivery.totalDistanceKm.toStringAsFixed(1)} km')),
                      Expanded(child: _Stat(label: 'Total Time', value: '${delivery.totalTimeMinutes} min')),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Expanded(child: _Stat(label: 'Delivered', value: '$delivered', color: AppColors.success)),
                      Expanded(child: _Stat(label: 'Delayed', value: '$delayed', color: delayed > 0 ? AppColors.warning : null)),
                      Expanded(child: _Stat(label: 'Cancelled', value: '$cancelled', color: cancelled > 0 ? AppColors.error : null)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Stop Recap', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            for (final stop in delivery.stops)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                  child: Row(
                    children: [
                      Icon(
                        stop.status == StopStatus.delivered
                            ? Icons.check_circle
                            : stop.status == StopStatus.delayed
                                ? Icons.schedule_rounded
                                : Icons.cancel_rounded,
                        size: 18,
                        color: stop.status.color,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(stop.customerName, style: AppTextStyles.bodyMd, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(stop.status.label, style: AppTextStyles.labelSm.copyWith(color: stop.status.color)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Back to Assigned Deliveries',
              icon: Icons.arrow_forward_rounded,
              onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.deliveryHome, (r) => false),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Stat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppTextStyles.headlineSm.copyWith(color: color)),
        Text(label, style: AppTextStyles.bodySm, textAlign: TextAlign.center),
      ],
    );
  }
}
