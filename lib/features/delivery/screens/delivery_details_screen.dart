import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/navigation_sheet.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/delivery.dart';
import '../../../data/models/user_role.dart';
import '../../../data/repositories/delivery_repository.dart';
import '../widgets/run_map_card.dart';

/// Full detail for a single delivery run — status, driver/vehicle, the run on
/// a map (branch, numbered customer pins, next stop highlighted), every stop
/// with its own status, and real actions persisted through
/// [DeliveryRepository]:
///
/// * owner / branch staff: assign or unassign a registered driver, mark a
///   stop delivered (runs without a registered driver), cancel the run;
/// * Navigate / Call buttons for every open stop while the run is active.
///
/// Shared with the rider-facing screens. When no registered driver carries
/// the run and no stop has started yet, "Start Delivery" opens the
/// staff-run route flow.
class DeliveryDetailsScreen extends StatefulWidget {
  final Delivery delivery;

  const DeliveryDetailsScreen({super.key, required this.delivery});

  @override
  State<DeliveryDetailsScreen> createState() => _DeliveryDetailsScreenState();
}

class _DeliveryDetailsScreenState extends State<DeliveryDetailsScreen> {
  late Delivery _delivery = widget.delivery;
  final Set<String> _updatingStops = {};
  bool _busy = false;

  bool get _manages {
    final role = AuthService.instance.currentProfile?.role;
    return role == UserRole.staff || role == UserRole.owner;
  }

  void _apply(Delivery updated) {
    StaffStore.instance.applyDelivery(updated);
    if (mounted) setState(() => _delivery = updated);
  }

  Future<void> _run(Future<Delivery> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await action();
      _apply(updated);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markDelivered(DeliveryStop stop) async {
    final previousStatus = stop.status;
    setState(() {
      _updatingStops.add(stop.id);
      stop.status = StopStatus.delivered;
    });
    try {
      final updated = await DeliveryRepository.instance.updateDeliveryStop(
        stopId: stop.id,
        status: 'delivered',
      );
      _apply(updated);
      if (!mounted) return;
      setState(() => _updatingStops.remove(stop.id));
      if (updated.isComplete) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${updated.id} marked completed — all stops delivered.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        stop.status = previousStatus;
        _updatingStops.remove(stop.id);
      });
      AppErrors.showSnack(context, e);
    }
  }

  Future<void> _assignDriver() async {
    final List<BranchDriver> drivers;
    try {
      drivers = await DeliveryRepository.instance.listDrivers(_delivery.branchId ?? StaffStore.instance.activeBranchId);
    } catch (e) {
      if (mounted) AppErrors.showSnack(context, e);
      return;
    }
    if (!mounted) return;
    final active = drivers.where((d) => d.isActive && (_delivery.branchId == null || d.branchId == _delivery.branchId)).toList()
      ..sort((a, b) => (b.isAvailable ? 1 : 0).compareTo(a.isAvailable ? 1 : 0));
    final picked = await showModalBottomSheet<BranchDriver>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: active.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('This branch has no active registered driver. The owner registers drivers in User Management.',
                    style: AppTextStyles.bodyMd, textAlign: TextAlign.center),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Text('Assign a driver', style: AppTextStyles.headlineSm),
                  ),
                  for (final d in active)
                    ListTile(
                      leading: Icon(Icons.delivery_dining_rounded, color: d.isAvailable ? AppColors.success : AppColors.textSecondary),
                      title: Text(d.fullName),
                      subtitle: Text([
                        d.isAvailable ? 'Available' : 'Off duty',
                        if (d.activeRuns > 0) '${d.activeRuns} open run${d.activeRuns == 1 ? '' : 's'}',
                        if ((d.vehicle ?? '').isNotEmpty) d.vehicle!,
                      ].join(' • ')),
                      onTap: () => Navigator.of(ctx).pop(d),
                    ),
                ],
              ),
      ),
    );
    if (picked == null) return;
    await _run(() => DeliveryRepository.instance.assignDriver(_delivery.id, picked.firebaseUid),
        '${picked.fullName} was asked to accept ${_delivery.id}.');
  }

  Future<void> _unassignDriver() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take the driver off this run?'),
        content: const Text('Possible until the driver accepts it. You can then assign someone else.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unassign')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => DeliveryRepository.instance.unassignDriver(_delivery.id, reason: 'Unassigned by branch'), 'Driver unassigned.');
  }

  Future<void> _cancelRun() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel ${_delivery.id}?'),
        content: const Text('Orders that were not delivered go back to the branch queue so they can be put on another run.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep run')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel run'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => DeliveryRepository.instance.cancelDelivery(_delivery.id), 'Run cancelled.');
  }

  @override
  Widget build(BuildContext context) {
    final delivery = _delivery;
    final active = delivery.status.isActive;
    final hasDriver = delivery.driverUid != null;
    final canAssign = _manages && active && !hasDriver;
    final canUnassign = _manages && active && delivery.driverStatus == 'assigned';

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: delivery.id,
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Route map',
            icon: const Icon(Icons.map_outlined),
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.routeMap, arguments: delivery),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(delivery.branch, style: AppTextStyles.titleMd)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: delivery.status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                        child: Text(delivery.status.label, style: AppTextStyles.labelSm.copyWith(color: delivery.status.color)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.local_shipping_outlined, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${delivery.vehicle} • ${delivery.riderName}', style: AppTextStyles.bodyMd)),
                      if ((delivery.driverPhone ?? '').isNotEmpty && active)
                        IconButton(
                          tooltip: 'Call driver',
                          icon: const Icon(Icons.call_outlined, size: 20),
                          onPressed: () => callNumber(context, delivery.driverPhone),
                        ),
                    ],
                  ),
                  Text(
                    hasDriver ? 'Registered driver • ${_driverStatus(delivery.driverStatus)}' : 'No registered driver assigned',
                    style: AppTextStyles.bodySm,
                  ),
                  if (canAssign || canUnassign) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (canAssign)
                          FilledButton.icon(
                            onPressed: _busy ? null : _assignDriver,
                            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                            label: const Text('Assign driver'),
                          ),
                        if (canUnassign)
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _unassignDriver,
                            icon: const Icon(Icons.person_remove_outlined, size: 18),
                            label: const Text('Unassign'),
                          ),
                      ],
                    ),
                  ],
                  const Divider(height: 20),
                  Row(
                    children: [
                      Expanded(child: _Stat(label: 'Distance', value: '${delivery.totalDistanceKm.toStringAsFixed(1)} km')),
                      Expanded(child: _Stat(label: 'Time', value: '${delivery.totalTimeMinutes} min')),
                      Expanded(child: _Stat(label: 'Progress', value: '${delivery.deliveredCount}/${delivery.stops.length}')),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            RunMapCard(
              delivery: delivery,
              onStopTap: (s) => Navigator.of(context).pushNamed(AppRoutes.routeMap, arguments: {'delivery': delivery, 'stopId': s.id}),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (!hasDriver && active && delivery.stops.every((s) => s.status == StopStatus.pending))
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: PrimaryButton(
                  label: 'Start Delivery',
                  icon: Icons.play_circle_outline_rounded,
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryRoute, arguments: delivery),
                ),
              ),
            Text('Delivery Stops', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < delivery.stops.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: delivery.stops[i].status.color.withValues(alpha: 0.15), shape: BoxShape.circle),
                            child: Text('${i + 1}', style: AppTextStyles.labelSm.copyWith(color: delivery.stops[i].status.color)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(delivery.stops[i].customerName, style: AppTextStyles.labelLg)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: delivery.stops[i].status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                            child: Text(delivery.stops[i].status.label, style: AppTextStyles.labelSm.copyWith(color: delivery.stops[i].status.color)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(delivery.stops[i].address, style: AppTextStyles.bodySm),
                      Text('${delivery.stops[i].orderId} • ETA ${delivery.stops[i].eta}', style: AppTextStyles.bodySm),
                      const SizedBox(height: 8),
                      StopNavigationActions(
                        delivery: delivery,
                        stop: delivery.stops[i],
                        trailing: [
                          // Runs carried by a registered driver are closed by the driver
                          // (proof + cash); staff close stops only on unregistered runs.
                          if (_manages && !hasDriver && active && !delivery.stops[i].isFinished)
                            SecondaryButton(
                              label: 'Mark as Delivered',
                              icon: Icons.check_circle_outline_rounded,
                              onPressed: _updatingStops.contains(delivery.stops[i].id)
                                  ? null
                                  : () => _markDelivered(delivery.stops[i]),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryManifest, arguments: delivery),
                    icon: const Icon(Icons.checklist_rounded, size: 16),
                    label: const Text('View Manifest'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.routeOptimization, arguments: delivery),
                    icon: const Icon(Icons.route_outlined, size: 16),
                    label: const Text('View Route'),
                  ),
                ),
              ],
            ),
            if (_manages && active) ...[
              const SizedBox(height: AppSpacing.md),
              TextButton.icon(
                onPressed: _busy ? null : _cancelRun,
                icon: const Icon(Icons.cancel_outlined, color: AppColors.error),
                label: const Text('Cancel run', style: TextStyle(color: AppColors.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _driverStatus(String? s) {
    switch (s) {
      case 'assigned':
        return 'waiting for them to accept';
      case 'accepted':
        return 'accepted, not picked up yet';
      case 'picked_up':
        return 'picked up';
      case 'in_transit':
        return 'on the road';
      case 'completed':
        return 'done';
      default:
        return 'assigned';
    }
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
