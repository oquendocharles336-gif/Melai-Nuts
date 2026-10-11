import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/views/branch_deliveries.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';

/// Delivery Management dashboard for the owner and branch staff (the admin
/// website no longer has any delivery function): active runs with driver,
/// vehicle, stops and next ETA, a map of the open stops' customer pins, and
/// entry points to the live driver map, the driver directory, creating a run,
/// and history. Staff see their branch; the owner sees the branch they are
/// viewing (and every branch on the live map).
///
/// Real deliveries loaded from the database. There is still no Google Maps
/// API or courier API — per-stop distance/time/ETA are a simple, honestly
/// labeled estimate, not real routing (see `staff_create_delivery`).
class DeliveryDashboardScreen extends StatelessWidget {
  const DeliveryDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _content(context, store));
  }

  Widget _content(BuildContext context, StaffStore store) {
    if (!store.deliveriesState.loaded && !store.deliveriesState.loading && store.deliveriesState.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.refreshDeliveries());
    }

    final active = activeDeliveries;
    // Every figure below is counted from the deliveries the database returned
    // (all loaded runs, not only today's). The database records no promised
    // delivery time, so an "on-time" rate cannot be computed and is not shown.
    final completed = kDeliveries.where((d) => d.status == DeliveryStatus.completed).length;
    final estimatedDistance = kDeliveries.fold<double>(0, (sum, d) => sum + d.totalDistanceKm);
    final totalStops = kDeliveries.fold<int>(0, (sum, d) => sum + d.stops.length);
    final deliveredStops = kDeliveries.fold<int>(0, (sum, d) => sum + d.deliveredCount);
    final deliveredRate = totalStops == 0 ? null : deliveredStops / totalStops * 100;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Delivery Management',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Delivery History',
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryHistory),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: store.refreshDeliveries,
          child: DataStateView(
            isLoading: store.deliveriesState.busy,
            error: store.deliveriesState.error,
            isEmpty: kDeliveries.isEmpty,
            emptyTitle: 'No deliveries yet',
            emptyMessage: 'Create a delivery to get started.',
            builder: (context) => ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
              children: [
                _StatTile(icon: Icons.local_shipping_outlined, label: 'Active Deliveries', value: '${active.length}', color: AppColors.roleDelivery),
                _StatTile(icon: Icons.check_circle_outline_rounded, label: 'Completed Runs', value: '$completed', color: AppColors.success),
                _StatTile(icon: Icons.route_outlined, label: 'Est. Distance (all runs)', value: '${estimatedDistance.toStringAsFixed(1)} km', color: AppColors.primary),
                _StatTile(
                  icon: Icons.task_alt_rounded,
                  label: 'Stops Delivered',
                  value: deliveredRate == null ? '—' : '$deliveredStops/$totalStops · ${deliveredRate.toStringAsFixed(0)}%',
                  color: AppColors.success,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _OpenStopsMap(active: active),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryLiveMap),
                    icon: const Icon(Icons.share_location_rounded, size: 18),
                    label: const Text('Live driver map'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDrivers),
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: const Text('Drivers'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: '+ Create Delivery',
              icon: Icons.add_road_rounded,
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryCreate),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Active Dispatches', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            if (active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text('No active deliveries right now.', style: AppTextStyles.bodyMd),
              )
            else
              for (final delivery in active)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DeliveryCard(
                    delivery: delivery,
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDetails, arguments: delivery),
                  ),
                ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryHistory),
                    icon: const Icon(Icons.history_rounded, size: 16),
                    label: const Text('View History'),
                  ),
                ),
              ],
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatTile({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: AppTextStyles.headlineSm.copyWith(color: color)),
          ),
          Text(label, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  final Delivery delivery;
  final VoidCallback onTap;

  const _DeliveryCard({required this.delivery, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
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
                Expanded(child: Text(delivery.id, style: AppTextStyles.labelLg)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: delivery.status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(delivery.status.label, style: AppTextStyles.labelSm.copyWith(color: delivery.status.color)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${delivery.branch} • ${delivery.vehicle} • ${delivery.riderName}', style: AppTextStyles.bodySm),
            Builder(builder: (context) {
              final next = RunMap.currentStop(delivery);
              final unpinned = RunMap.unpinnedOpenStops(delivery).length;
              final parts = [
                _driverLabel(delivery),
                if (next != null) 'Next: ${next.customerName}${next.eta.isEmpty ? '' : ' • ETA ${next.eta}'}',
                if (unpinned > 0) '$unpinned without map pin',
              ];
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(parts.join(' • '),
                    style: AppTextStyles.bodySm.copyWith(color: unpinned > 0 ? AppColors.warning : AppColors.textSecondary)),
              );
            }),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _MiniStat(icon: Icons.pin_drop_outlined, label: '${delivery.stops.length} stops')),
                Expanded(child: _MiniStat(icon: Icons.route_outlined, label: '${delivery.totalDistanceKm.toStringAsFixed(1)} km')),
                Expanded(child: _MiniStat(icon: Icons.schedule_outlined, label: '${delivery.totalTimeMinutes} min')),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: delivery.stops.isEmpty ? 0 : delivery.deliveredCount / delivery.stops.length,
                minHeight: 6,
                backgroundColor: AppColors.border,
                color: AppColors.success,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MiniStat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Expanded(child: Text(label, style: AppTextStyles.bodySm, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}


String _driverLabel(Delivery d) {
  switch (d.driverStatus) {
    case 'assigned':
      return 'Waiting for driver to accept';
    case 'accepted':
      return 'Driver accepted';
    case 'picked_up':
      return 'Picked up';
    case 'in_transit':
      return 'On the road';
    case 'completed':
      return 'Done';
    default:
      return d.driverUid == null ? 'No registered driver' : 'Driver assigned';
  }
}

/// The customers' pins of every open stop on the active runs, with their
/// branch: where the deliveries of the day are going. Driver positions are on
/// the live map (refreshed every 10 s).
class _OpenStopsMap extends StatelessWidget {
  final List<Delivery> active;
  const _OpenStopsMap({required this.active});

  @override
  Widget build(BuildContext context) {
    final stops = <MapStop>[
      for (final run in active)
        for (final s in RunMap.mapStops(run))
          if (!s.done && !s.failed) MapStop(point: s.point, label: '${run.id} • ${s.label}', number: s.number, current: s.current),
    ];
    final branches = <String, MapBranch>{};
    for (final run in active) {
      final p = DeliveryMap.point(run.branchLatitude, run.branchLongitude);
      if (p != null) branches[run.branch] = MapBranch(point: p, label: run.branch);
    }
    if (stops.isEmpty && branches.isEmpty) {
      return active.isEmpty
          ? const SizedBox.shrink()
          : const NoPinNotice(text: 'No open stop has a customer pin yet, so there is nothing to map. Call those customers.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where today\'s open stops are', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.xs),
        DeliveryMap(stops: stops, branches: branches.values.toList(), showRouteLine: false, height: 220),
      ],
    );
  }
}
