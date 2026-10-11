import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/navigation_sheet.dart';
import '../../../data/models/delivery.dart';

/// Map helpers for a delivery run, shared by the driver's screens and the
/// owner / staff delivery screens so every run looks the same:
/// branch, numbered stops in order, the current / next stop highlighted,
/// finished stops green (delivered) or red (failed), and the driver.
class RunMap {
  RunMap._();

  /// The stop being worked on: the first one (in run order) that is not
  /// finished. Null when every stop is finished.
  static DeliveryStop? currentStop(Delivery d) {
    final open = d.stops.where((s) => !s.isFinished).toList()
      ..sort((a, b) => a.sequenceIndex.compareTo(b.sequenceIndex));
    return open.isEmpty ? null : open.first;
  }

  /// Stops that have a valid customer pin, as map markers.
  static List<MapStop> mapStops(Delivery d, {String? focusStopId, void Function(DeliveryStop stop)? onTap}) {
    final focus = focusStopId ?? currentStop(d)?.id;
    return [
      for (final s in d.stops)
        if (DeliveryMap.point(s.latitude, s.longitude) != null)
          MapStop(
            point: DeliveryMap.point(s.latitude, s.longitude)!,
            label: '${s.sequenceIndex + 1}. ${s.customerName}',
            number: s.sequenceIndex + 1,
            done: s.status == StopStatus.delivered,
            failed: s.status == StopStatus.failed || s.status == StopStatus.skipped,
            current: s.id == focus && !s.isFinished,
            onTap: onTap == null ? null : () => onTap(s),
          ),
    ];
  }

  /// Open stops whose customer did not pin a location.
  static List<DeliveryStop> unpinnedOpenStops(Delivery d) =>
      d.stops.where((s) => !s.isFinished && DeliveryMap.point(s.latitude, s.longitude) == null).toList();
}

/// A run on a map with the "no pin" notices underneath. Shows only the
/// notice when nothing on the run has coordinates (never an empty map).
class RunMapCard extends StatelessWidget {
  final Delivery delivery;
  final LatLng? driver;
  final String driverLabel;
  final String? focusStopId;
  final double height;
  final void Function(DeliveryStop stop)? onStopTap;

  const RunMapCard({
    super.key,
    required this.delivery,
    this.driver,
    this.driverLabel = 'Driver',
    this.focusStopId,
    this.height = 240,
    this.onStopTap,
  });

  @override
  Widget build(BuildContext context) {
    final stops = RunMap.mapStops(delivery, focusStopId: focusStopId, onTap: onStopTap);
    final branch = DeliveryMap.point(delivery.branchLatitude, delivery.branchLongitude);
    final unpinned = RunMap.unpinnedOpenStops(delivery);
    final hasMap = stops.isNotEmpty || branch != null || driver != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasMap)
          DeliveryMap(
            branch: branch,
            branchLabel: delivery.branch,
            stops: stops,
            driver: driver,
            driverLabel: driverLabel,
            height: height,
          ),
        if (stops.isEmpty && delivery.stops.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: hasMap ? AppSpacing.xs : 0),
            child: const NoPinNotice(
              text: 'None of these customers pinned a location on the map. Use the address text and call them.',
            ),
          )
        else if (unpinned.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: NoPinNotice(
              text: unpinned.length == 1
                  ? 'Stop ${unpinned.first.sequenceIndex + 1} (${unpinned.first.customerName}) has no map pin — call them.'
                  : '${unpinned.length} stops have no map pin (${unpinned.map((s) => s.sequenceIndex + 1).join(', ')}) — call those customers.',
            ),
          ),
      ],
    );
  }
}

/// "Customer didn't pin a location" warning, optionally with a call button.
class NoPinNotice extends StatelessWidget {
  final String text;
  final String? phone;

  const NoPinNotice({super.key, this.text = "Customer didn't pin a location – call them.", this.phone});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wrong_location_outlined, color: AppColors.warning, size: 20),
          const SizedBox(width: AppSpacing.xs),
          Expanded(child: Text(text, style: AppTextStyles.bodySm)),
          if ((phone ?? '').trim().isNotEmpty)
            TextButton.icon(
              onPressed: () => callNumber(context, phone),
              icon: const Icon(Icons.call_outlined, size: 18),
              label: const Text('Call'),
            ),
        ],
      ),
    );
  }
}

/// Navigate / Call buttons for one stop. Only shown while the stop and the
/// run are still open: afterwards the server hides the address, pin and
/// phone anyway (privacy rule), so there is nothing to navigate to.
class StopNavigationActions extends StatelessWidget {
  final Delivery delivery;
  final DeliveryStop stop;

  /// Extra buttons (e.g. the driver's "Delivered").
  final List<Widget> trailing;

  const StopNavigationActions({super.key, required this.delivery, required this.stop, this.trailing = const []});

  bool get _open => delivery.status.isActive && !stop.isFinished;

  @override
  Widget build(BuildContext context) {
    if (!_open) return const SizedBox.shrink();
    final pinned = DeliveryMap.point(stop.latitude, stop.longitude) != null;
    final hasPhone = (stop.contactPhone ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!pinned)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: NoPinNotice(phone: hasPhone ? stop.contactPhone : null),
          ),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            OutlinedButton.icon(
              onPressed: () => showNavigationSheet(
                context,
                latitude: stop.latitude,
                longitude: stop.longitude,
                address: stop.address,
              ),
              icon: const Icon(Icons.navigation_outlined, size: 18),
              label: Text(pinned ? 'Navigate' : 'Navigate (address)'),
            ),
            if (hasPhone)
              OutlinedButton.icon(
                onPressed: () => callNumber(context, stop.contactPhone),
                icon: const Icon(Icons.call_outlined, size: 18),
                label: const Text('Call customer'),
              ),
            ...trailing,
          ],
        ),
      ],
    );
  }
}
