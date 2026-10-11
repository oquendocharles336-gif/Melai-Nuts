import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';

/// Focused view of the immediate next stop: the customer's pin highlighted on
/// the run map (with the branch and the other stops), Navigate (Google Maps /
/// Waze / Apple Maps on the pin) and Call while the run is active, and
/// "Update Status" actions (Delivered / Delayed / Cancelled) — the step right
/// before Confirmation in the rider flow. Without a pin it says so plainly.
class NextStopScreen extends StatelessWidget {
  final Delivery delivery;

  const NextStopScreen({super.key, required this.delivery});

  DeliveryStop? get _nextStop {
    for (final s in delivery.stops) {
      if (s.status == StopStatus.pending || s.status == StopStatus.enRoute) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stop = _nextStop;

    if (stop == null) {
      return Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: const MelaiAppBar(title: 'Next Stop', showBack: true),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline_rounded, size: 56, color: AppColors.success),
                  const SizedBox(height: 12),
                  Text('All stops handled for this delivery.', style: AppTextStyles.titleMd, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'View Completion Summary',
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryCompleted, arguments: delivery),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final stopIndex = delivery.stops.indexOf(stop);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Next Stop', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(20)),
              child: Text('STOP ${stopIndex + 1} OF ${delivery.stops.length}', style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                        child: const Icon(Icons.person, color: AppColors.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(stop.customerName, style: AppTextStyles.titleMd),
                            Text(stop.orderId, style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Icon(Icons.location_on_outlined, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(child: Text(stop.address, style: AppTextStyles.bodyMd)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: _Stat(label: 'Distance', value: '${stop.distanceFromPreviousKm.toStringAsFixed(1)} km')),
                      Expanded(child: _Stat(label: 'ETA', value: stop.eta)),
                    ],
                  ),
                  const Divider(height: 20),
                  Text('ITEMS TO DELIVER', style: AppTextStyles.labelSm),
                  const SizedBox(height: 4),
                  for (final item in stop.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Icon(Icons.circle, size: 6, color: AppColors.textSecondary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(item, style: AppTextStyles.bodyMd)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            RunMapCard(
              delivery: delivery,
              focusStopId: stop.id,
              height: 220,
              onStopTap: (s) => Navigator.of(context).pushNamed(AppRoutes.routeMap, arguments: {'delivery': delivery, 'stopId': s.id}),
            ),
            const SizedBox(height: AppSpacing.md),
            StopNavigationActions(delivery: delivery, stop: stop),
            const SizedBox(height: AppSpacing.lg),
            Text('Update Status', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            PrimaryButton(
              label: 'Mark as Delivered',
              icon: Icons.check_circle_outline_rounded,
              onPressed: () => Navigator.of(context).pushNamed(
                AppRoutes.deliveryConfirmation,
                arguments: {'delivery': delivery, 'stop': stop},
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: 'Report Delay',
                    icon: Icons.schedule_outlined,
                    onPressed: () => Navigator.of(context).pushNamed(
                      AppRoutes.deliveryDelayed,
                      arguments: {'delivery': delivery, 'stop': stop},
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SecondaryButton(
                    label: 'Cancel Stop',
                    icon: Icons.cancel_outlined,
                    onPressed: () => Navigator.of(context).pushNamed(
                      AppRoutes.deliveryCancelled,
                      arguments: {'delivery': delivery, 'stop': stop},
                    ),
                  ),
                ),
              ],
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

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.bodySm),
        Text(value, style: AppTextStyles.labelLg),
      ],
    );
  }
}
