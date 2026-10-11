import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';
import '../../../data/repositories/delivery_repository.dart';

/// "Start Delivery" step — the run's stop order as saved in the database,
/// with the per-stop distance/time estimate the server made when the run was
/// created (not real routing), and a "Start Delivery" action that marks the
/// first stop en route and opens live tracking.
class DeliveryRouteScreen extends StatefulWidget {
  final Delivery delivery;

  const DeliveryRouteScreen({super.key, required this.delivery});

  @override
  State<DeliveryRouteScreen> createState() => _DeliveryRouteScreenState();
}

class _DeliveryRouteScreenState extends State<DeliveryRouteScreen> {
  Delivery get delivery => widget.delivery;
  bool _starting = false;

  // Uses State.context (no parameter) so the `mounted` checks below guard
  // the same context that is used after the await.
  Future<void> _startDelivery() async {
    if (delivery.stops.isEmpty) {
      Navigator.of(context).pushReplacementNamed(AppRoutes.gpsTracking, arguments: delivery);
      return;
    }
    setState(() => _starting = true);
    try {
      final firstStop = delivery.stops.first;
      final updated = await DeliveryRepository.instance.updateDeliveryStop(
        stopId: firstStop.id,
        status: 'enRoute',
      );
      StaffStore.instance.applyDelivery(updated);
      if (!mounted) return;
      delivery.status = updated.status;
      if (firstStop.status == StopStatus.pending) {
        firstStop.status = StopStatus.enRoute;
      }
      Navigator.of(context).pushReplacementNamed(AppRoutes.gpsTracking, arguments: delivery);
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Stop Order',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.routeMap, arguments: delivery),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            // The run on the map: customer pins in stop order, next stop highlighted.
            RunMapCard(delivery: delivery, height: 220),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.successBg,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.route_rounded, color: AppColors.success),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${delivery.stops.length} stops • about ${delivery.totalDistanceKm.toStringAsFixed(1)} km • about ${delivery.totalTimeMinutes} min (estimate).',
                      style: AppTextStyles.bodyMd,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Stop Sequence', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            _Node(icon: Icons.storefront_rounded, iconColor: AppColors.roleOwner, title: delivery.branch, subtitle: 'Start here • ${delivery.vehicle}', isFirst: true, isLast: false),
            for (int i = 0; i < delivery.stops.length; i++)
              _Node(
                icon: Icons.location_on_rounded,
                iconColor: delivery.stops[i].status.color,
                title: '${i + 1}. ${delivery.stops[i].customerName}',
                subtitle: '${delivery.stops[i].distanceFromPreviousKm.toStringAsFixed(1)} km • ${delivery.stops[i].travelMinutesFromPrevious} min • ETA ${delivery.stops[i].eta}',
                isFirst: false,
                isLast: i == delivery.stops.length - 1,
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
                      'Distances and times are estimates, not road routing. Live position appears on the tracking screen only while a registered driver shares location.',
                      style: AppTextStyles.bodySm,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Start Delivery',
              icon: Icons.play_circle_outline_rounded,
              loading: _starting,
              onPressed: _starting ? null : _startDelivery,
            ),
          ],
        ),
      ),
    );
  }
}

class _Node extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isFirst;
  final bool isLast;

  const _Node({required this.icon, required this.iconColor, required this.title, required this.subtitle, required this.isFirst, required this.isLast});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              if (!isFirst) Container(width: 2, height: 16, color: AppColors.border),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(icon, size: 15, color: iconColor),
              ),
              if (!isLast) Expanded(child: Container(width: 2, color: AppColors.border)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: 16, top: isFirst ? 0 : 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLg),
                  Text(subtitle, style: AppTextStyles.bodySm),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
