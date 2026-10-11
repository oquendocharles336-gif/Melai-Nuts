import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/delivery.dart';
import '../../../data/repositories/delivery_repository.dart';
import '../widgets/run_map_card.dart';

/// Live tracking of one run, from the database.
///
/// Shows the GPS points the registered driver's phone actually recorded
/// (`staff_get_delivery_tracking`, refreshed every 15 seconds) on the map
/// together with the branch and the stops that have coordinates. When no
/// position has been recorded (no registered driver, location sharing off, or
/// the run has not been picked up) the screen says so and draws no vehicle —
/// nothing is animated or estimated.
class GpsTrackingScreen extends StatefulWidget {
  final Delivery delivery;

  const GpsTrackingScreen({super.key, required this.delivery});

  @override
  State<GpsTrackingScreen> createState() => _GpsTrackingScreenState();
}

class _GpsTrackingScreenState extends State<GpsTrackingScreen> {
  static const Duration _refreshEvery = Duration(seconds: 15);
  static final DateFormat _time = DateFormat('MMM d, h:mm:ss a');

  DeliveryTracking? _tracking;
  Object? _error;
  bool _loading = true;
  Timer? _timer;

  Delivery get _delivery => _tracking?.delivery ?? widget.delivery;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(_refreshEvery, (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final t = await DeliveryRepository.instance.getTracking(widget.delivery.id);
      if (!mounted) return;
      setState(() {
        _tracking = t;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Keep the last real data (if any) and show the failure; never fill in a position.
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  DeliveryStop? get _nextStop {
    for (final s in _delivery.stops) {
      if (s.status == StopStatus.enRoute || s.status == StopStatus.pending || s.status == StopStatus.delayed) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final delivery = _delivery;
    final nextStop = _nextStop;
    final latest = _tracking?.latest;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LIVE TRACKING', style: AppTextStyles.labelSm),
            Text('Delivery ${delivery.id}', style: AppTextStyles.titleMd),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh', onPressed: _loading ? null : _load),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (_loading && _tracking == null)
                const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: StateLoadingView(message: 'Loading the latest position...'))
              else if (_error != null && _tracking == null)
                StateErrorView(error: _error, onRetry: _load)
              else ...[
                if (_error != null)
                  StaleDataBanner(error: _error!, onRetry: _load),
                _statusBanner(latest),
                const SizedBox(height: AppSpacing.md),
                _map(delivery, latest),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (nextStop != null)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('NEXT STOP', style: AppTextStyles.labelSm),
                      Text(nextStop.customerName, style: AppTextStyles.titleMd),
                      Text(nextStop.address, style: AppTextStyles.bodySm),
                      const Divider(height: 20),
                      Row(
                        children: [
                          Expanded(child: _Stat(label: 'Est. distance', value: '${nextStop.distanceFromPreviousKm.toStringAsFixed(1)} km')),
                          Expanded(child: _Stat(label: 'Est. arrival', value: nextStop.eta.isEmpty ? '—' : nextStop.eta)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('Distance and arrival are the estimate made when the run was created, not live routing.', style: AppTextStyles.bodySm),
                    ],
                  ),
                )
              else
                Text('Every stop on this run has been handled.', style: AppTextStyles.bodyMd),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'View Next Stop',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryNextStop, arguments: delivery),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBanner(TrackPoint? latest) {
    final has = latest != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: has ? AppColors.successBg : AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: has ? AppColors.success.withValues(alpha: 0.3) : AppColors.border),
      ),
      child: Row(
        children: [
          Icon(has ? Icons.gps_fixed_rounded : Icons.gps_off_rounded, size: 18, color: has ? AppColors.success : AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              has
                  ? 'Last position recorded ${_time.format(latest.recordedAt)}'
                      '${latest.accuracyM != null ? ' (±${latest.accuracyM!.toStringAsFixed(0)} m)' : ''}. Refreshes every 15 seconds.'
                  : 'No live location for this run. Positions appear only while a registered driver has picked up the run '
                      'and is sharing location from the Melai Nuts driver app.',
              style: AppTextStyles.bodySm,
            ),
          ),
        ],
      ),
    );
  }

  /// The run with its driver's latest point, the customers' pins in stop
  /// order and the next stop highlighted; "no pin" stops are listed under it.
  Widget _map(Delivery d, TrackPoint? latest) {
    final driver = latest == null ? null : DeliveryMap.point(latest.latitude, latest.longitude);
    final branch = DeliveryMap.point(d.branchLatitude, d.branchLongitude);
    if (branch == null && RunMap.mapStops(d).isEmpty && driver == null && d.stops.isEmpty) {
      return const StateEmptyView(
        icon: Icons.map_outlined,
        title: 'Nothing to show on the map',
        message: 'This branch and these delivery addresses have no map coordinates, and no driver position has been recorded.',
        compact: true,
      );
    }
    return RunMapCard(delivery: d, driver: driver, driverLabel: d.riderName, height: 300);
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
