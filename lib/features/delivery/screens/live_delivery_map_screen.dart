import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/navigation_sheet.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/models/delivery.dart';
import '../../../data/repositories/delivery_repository.dart';
import '../widgets/run_map_card.dart';

/// Live map of the runs being carried right now — what the admin website's
/// "Driver tracking" page used to show, now only in the app.
///
/// * Owner: every branch (or one, with the switch); staff: their branch. The
///   database scopes both calls (`staff_get_deliveries`,
///   `staff_active_driver_positions`).
/// * Driver markers (tap one for the run, its stops and ETA), the customers'
///   pins of the open stops, and the branches.
/// * Refreshes every 10 seconds while the screen is open. A failed refresh
///   keeps the last real positions on screen and says so.
class LiveDeliveryMapScreen extends StatelessWidget {
  const LiveDeliveryMapScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      StaffDataScope(builder: (context, store) => _LiveMapBody(store: store));
}

class _LiveMapBody extends StatefulWidget {
  final StaffStore store;
  const _LiveMapBody({required this.store});

  @override
  State<_LiveMapBody> createState() => _LiveMapBodyState();
}

class _LiveMapBodyState extends State<_LiveMapBody> with WidgetsBindingObserver {
  static const Duration refreshEvery = Duration(seconds: 10);

  final _repo = DeliveryRepository.instance;
  Timer? _timer;
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  DateTime? _updatedAt;
  List<Delivery> _runs = const [];
  List<DriverPosition> _positions = const [];

  /// Owner only: all branches (default) or the branch they are viewing.
  bool _allBranches = true;

  String? get _scope => widget.store.isOwner && _allBranches ? null : widget.store.activeBranchId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(refreshEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Polling only while the app is on screen (light use of the database).
    if (state == AppLifecycleState.resumed) {
      _timer ??= Timer.periodic(refreshEvery, (_) => _refresh());
      _refresh();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final scope = _scope;
    if (!widget.store.isOwner && scope == null) {
      setState(() {
        _loading = false;
        _error = const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
      });
      return;
    }
    _busy = true;
    try {
      final results = await Future.wait([
        _repo.getDeliveries(scope),
        _repo.activeDriverPositions(scope),
      ]);
      if (!mounted) return;
      setState(() {
        _runs = (results[0] as List<Delivery>).where((d) => d.status.isActive).toList();
        _positions = results[1] as List<DriverPosition>;
        _error = null;
        _loading = false;
        _updatedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      _busy = false;
    }
  }

  Delivery? _runFor(String deliveryId) {
    for (final r in _runs) {
      if (r.id == deliveryId) return r;
    }
    return null;
  }

  void _showRun(Delivery? run, DriverPosition? position) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
          child: _RunSummary(
            run: run,
            position: position,
            onOpen: run == null
                ? null
                : () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pushNamed(AppRoutes.deliveryDetails, arguments: run);
                  },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drivers = [
      for (final p in _positions)
        if (DeliveryMap.point(p.latitude, p.longitude) != null)
          MapDriver(
            point: DeliveryMap.point(p.latitude, p.longitude)!,
            label: '${p.driverName} • ${p.deliveryId}',
            onTap: () => _showRun(_runFor(p.deliveryId), p),
          ),
    ];
    final stops = <MapStop>[
      for (final run in _runs)
        for (final s in RunMap.mapStops(run))
          if (!s.done && !s.failed)
            MapStop(
              point: s.point,
              label: '${run.id} • ${s.label}',
              number: s.number,
              current: s.current,
              onTap: () => _showRun(run, null),
            ),
    ];
    final branchMarkers = <String, MapBranch>{};
    for (final run in _runs) {
      final p = DeliveryMap.point(run.branchLatitude, run.branchLongitude);
      if (p != null) branchMarkers[run.branch] = MapBranch(point: p, label: run.branch);
    }
    final unpinned = _runs.fold<int>(0, (n, r) => n + RunMap.unpinnedOpenStops(r).length);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Live delivery map',
        showBack: true,
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _refresh),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.store.isOwner)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
                child: SegmentedButton<bool>(
                  segments: [
                    const ButtonSegment(value: true, label: Text('All branches'), icon: Icon(Icons.public_rounded)),
                    ButtonSegment(
                      value: false,
                      label: Text(widget.store.activeBranchName.isEmpty ? 'This branch' : widget.store.activeBranchName),
                      icon: const Icon(Icons.storefront_outlined),
                    ),
                  ],
                  selected: {_allBranches},
                  onSelectionChanged: (v) {
                    setState(() => _allBranches = v.first);
                    _refresh();
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _updatedAt == null
                          ? 'Loading…'
                          : '${_positions.length} driver${_positions.length == 1 ? '' : 's'} out • ${_runs.length} open run${_runs.length == 1 ? '' : 's'} • updated ${TimeOfDay.fromDateTime(_updatedAt!).format(context)}',
                      style: AppTextStyles.bodySm,
                    ),
                  ),
                  if (_error != null && _updatedAt != null)
                    Text('Refresh failed', style: AppTextStyles.labelSm.copyWith(color: AppColors.error)),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : (_error != null && _updatedAt == null)
                        ? Center(child: Text(AppErrors.from(_error!).message, textAlign: TextAlign.center))
                        : (drivers.isEmpty && stops.isEmpty && branchMarkers.isEmpty)
                            ? Center(
                                child: Text(
                                  'No driver is out right now, and no open run has a customer pin or a branch position.',
                                  textAlign: TextAlign.center,
                                  style: AppTextStyles.bodyMd,
                                ),
                              )
                            : DeliveryMap(
                                height: null,
                                drivers: drivers,
                                stops: stops,
                                branches: branchMarkers.values.toList(),
                                showRouteLine: false,
                              ),
              ),
            ),
            if (unpinned > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
                child: NoPinNotice(text: '$unpinned open stop${unpinned == 1 ? '' : 's'} without a customer pin (not on the map).'),
              ),
            Expanded(
              flex: 2,
              child: _runs.isEmpty
                  ? Center(child: Text('No open runs.', style: AppTextStyles.bodyMd))
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      itemCount: _runs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final run = _runs[i];
                        DriverPosition? pos;
                        for (final p in _positions) {
                          if (p.deliveryId == run.id) pos = p;
                        }
                        return _RunTile(run: run, position: pos, onTap: () => _showRun(run, pos));
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

String _driverStatusLabel(String? s) {
  switch (s) {
    case 'assigned':
      return 'Waiting for driver';
    case 'accepted':
      return 'Accepted';
    case 'picked_up':
      return 'Picked up';
    case 'in_transit':
      return 'On the road';
    case 'completed':
      return 'Done';
    default:
      return 'No registered driver';
  }
}

class _RunTile extends StatelessWidget {
  final Delivery run;
  final DriverPosition? position;
  final VoidCallback onTap;
  const _RunTile({required this.run, required this.position, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final next = RunMap.currentStop(run);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(position != null ? Icons.delivery_dining_rounded : Icons.local_shipping_outlined,
                color: position != null ? AppColors.roleDelivery : AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${run.id} • ${run.riderName.isEmpty ? 'No driver' : run.riderName}',
                      style: AppTextStyles.labelLg, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${run.branch} • ${run.vehicle} • ${run.deliveredCount}/${run.stops.length} delivered'
                    '${next == null ? '' : ' • next: ${next.customerName}${next.eta.isEmpty ? '' : ' (ETA ${next.eta})'}'}',
                    style: AppTextStyles.bodySm,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(_driverStatusLabel(run.driverStatus), style: AppTextStyles.labelSm.copyWith(color: run.status.color)),
          ],
        ),
      ),
    );
  }
}

class _RunSummary extends StatelessWidget {
  final Delivery? run;
  final DriverPosition? position;
  final VoidCallback? onOpen;
  const _RunSummary({required this.run, required this.position, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final r = run;
    final p = position;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r?.id ?? p?.deliveryId ?? 'Run', style: AppTextStyles.headlineSm),
        const SizedBox(height: 4),
        Text(
          [
            r?.riderName ?? p?.driverName ?? 'Driver',
            if (r != null) _driverStatusLabel(r.driverStatus),
            r?.branch ?? p?.branch ?? '',
            if ((r?.vehicle ?? '').isNotEmpty) r!.vehicle,
          ].where((x) => x.isNotEmpty).join(' • '),
          style: AppTextStyles.bodyMd,
        ),
        if (p?.recordedAt != null)
          Text('Position updated ${friendlyTime(p!.recordedAt!)}', style: AppTextStyles.bodySm),
        if (r != null) ...[
          const SizedBox(height: AppSpacing.sm),
          for (final s in r.stops)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: s.status.color.withValues(alpha: 0.15),
                    child: Text('${s.sequenceIndex + 1}', style: AppTextStyles.labelSm.copyWith(color: s.status.color)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.customerName, style: AppTextStyles.bodyMd, overflow: TextOverflow.ellipsis)),
                  if (DeliveryMap.point(s.latitude, s.longitude) == null && !s.isFinished)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.wrong_location_outlined, size: 16, color: AppColors.warning),
                    ),
                  Text(s.isFinished ? s.status.label : (s.eta.isEmpty ? s.status.label : 'ETA ${s.eta}'),
                      style: AppTextStyles.bodySm),
                ],
              ),
            ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (onOpen != null)
              FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.open_in_new_rounded, size: 18), label: const Text('Open run')),
            if ((r?.driverPhone ?? '').isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => callNumber(context, r!.driverPhone),
                icon: const Icon(Icons.call_outlined, size: 18),
                label: const Text('Call driver'),
              ),
          ],
        ),
      ],
    );
  }
}
