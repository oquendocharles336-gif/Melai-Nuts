import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';

/// The run on a real map (OpenStreetMap via [DeliveryMap]): the branch, every
/// customer's pin numbered in stop order, the current / next stop (or the one
/// opened with [focusStopId]) highlighted, delivered stops green and failed
/// ones red. Stops without a pin are listed with a "call them" notice — no
/// made-up positions. While the run is active each open stop has Navigate
/// (Google Maps / Waze / Apple Maps) and Call buttons.
class RouteMapScreen extends StatefulWidget {
  final Delivery delivery;
  final String? focusStopId;

  const RouteMapScreen({super.key, required this.delivery, this.focusStopId});

  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  late String? _focus = widget.focusStopId ?? RunMap.currentStop(widget.delivery)?.id;

  @override
  Widget build(BuildContext context) {
    final delivery = widget.delivery;
    final pinnedCount = RunMap.mapStops(delivery).length;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Route Map • ${delivery.id}', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.border)),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pinnedCount > 0
                          ? 'Pins are where each customer pinned their delivery. Lines show the stop order, not the road.'
                          : 'No customer on this run pinned a location yet. The stop order is listed below.',
                      style: AppTextStyles.bodySm,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            RunMapCard(
              delivery: delivery,
              focusStopId: _focus,
              height: 360,
              onStopTap: (s) => setState(() => _focus = s.id),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Stops on This Route', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            for (final stop in delivery.stops)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  onTap: () => setState(() => _focus = stop.id),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: stop.id == _focus ? AppColors.warning : AppColors.border, width: stop.id == _focus ? 2 : 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: stop.status.color.withValues(alpha: 0.15), shape: BoxShape.circle),
                              child: Text('${stop.sequenceIndex + 1}', style: AppTextStyles.labelSm.copyWith(color: stop.status.color)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(stop.customerName, style: AppTextStyles.labelLg, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(stop.address, style: AppTextStyles.bodySm, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  Text('${stop.status.label} • ~${stop.distanceFromPreviousKm.toStringAsFixed(1)} km • est. ${stop.eta}',
                                      style: AppTextStyles.bodySm),
                                ],
                              ),
                            ),
                            if (DeliveryMap.point(stop.latitude, stop.longitude) == null && !stop.isFinished)
                              const Tooltip(
                                message: 'No map pin',
                                child: Icon(Icons.wrong_location_outlined, color: AppColors.warning),
                              ),
                          ],
                        ),
                        if (stop.id == _focus) ...[
                          const SizedBox(height: 8),
                          StopNavigationActions(delivery: delivery, stop: stop),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
