import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/geo_utils.dart';

/// The one place that decides which map tiles every map in the app uses.
///
/// Tiles are OpenStreetMap's: free and no API key, so nothing secret ships in
/// the app. OSM's tile policy asks for a real User-Agent (the package name
/// below), the attribution shown on every map and light use; flutter_map's
/// default tile provider caches tiles while the map is open. For heavy
/// traffic point [url] at a paid or own tile server — nothing else changes.
class MapTiles {
  MapTiles._();

  static const String url = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackageName = 'ph.melainuts.app';
  static const String attributionText = 'OpenStreetMap contributors';
  static final Uri attributionUri = Uri.parse('https://openstreetmap.org/copyright');

  /// Widget tests turn tiles off (no network in tests); the markers, legend
  /// and controls still render.
  static bool enabled = true;

  static Widget tileLayer() => TileLayer(
        urlTemplate: url,
        userAgentPackageName: userAgentPackageName,
        maxNativeZoom: 19,
      );

  static Widget attribution() => RichAttributionWidget(
        alignment: AttributionAlignment.bottomRight,
        attributions: [
          TextSourceAttribution(attributionText, onTap: () => launchUrl(attributionUri)),
        ],
      );
}

/// Marker colors / icons shared by every map, so a branch, a customer pin, a
/// driver or a finished stop looks the same everywhere.
class MapMarkerStyle {
  MapMarkerStyle._();

  static const Color branch = AppColors.darkBrown;
  static const Color customerPin = AppColors.primary;
  static const Color stop = AppColors.primary;
  static const Color currentStop = AppColors.warning;
  static const Color delivered = AppColors.success;
  static const Color failed = AppColors.error;
  static const Color driver = AppColors.roleDelivery;
  static const Color candidate = AppColors.textSecondary;

  static const IconData branchIcon = Icons.storefront_rounded;
  static const IconData customerPinIcon = Icons.location_on_rounded;
  static const IconData driverIcon = Icons.delivery_dining_rounded;
}

/// One numbered stop on a [DeliveryMap].
class MapStop {
  final LatLng point;
  final String label;
  final bool done;
  final bool failed;

  /// The stop the driver is on / goes to next: drawn larger and highlighted.
  final bool current;
  final VoidCallback? onTap;

  /// The number shown on the marker (defaults to its position in the list).
  final int? number;

  /// A candidate that is not part of the run (yet): grey, marked "+", not on
  /// the route line. Used when picking orders for a new run.
  final bool faded;

  const MapStop({
    required this.point,
    required this.label,
    this.done = false,
    this.failed = false,
    this.current = false,
    this.onTap,
    this.number,
    this.faded = false,
  });
}

/// An extra branch marker (the owner's all-branch live map).
class MapBranch {
  final LatLng point;
  final String label;
  const MapBranch({required this.point, required this.label});
}

/// A driver's latest shared position (live maps can show several).
class MapDriver {
  final LatLng point;
  final String label;
  final VoidCallback? onTap;
  const MapDriver({required this.point, required this.label, this.onTap});
}

/// The app's delivery map: the branch, numbered stops in order (joined by
/// straight lines — the order of the run, not a road route), a single
/// customer pin, and driver positions.
///
/// * fits every point on load, with zoom +/- and a "recenter" button;
/// * a legend when more than one kind of marker is shown;
/// * points without valid coordinates are simply left off — callers build
///   points with [DeliveryMap.point], and invalid ones are dropped here too,
///   so a map is never centered on 0,0;
/// * with no valid point at all nothing is drawn (callers show their own
///   "no pin" notice).
class DeliveryMap extends StatefulWidget {
  /// Kept for older callers: the tile URL lives in [MapTiles.url].
  static const String tileUrl = MapTiles.url;

  final LatLng? branch;
  final String branchLabel;
  final List<MapStop> stops;
  final LatLng? driver;
  final String driverLabel;

  /// Extra drivers (the owner / staff live map).
  final List<MapDriver> drivers;

  /// Extra branches (the owner's all-branch live map).
  final List<MapBranch> branches;

  /// A single customer pin (an address, an order's destination).
  final LatLng? pin;
  final String pinLabel;

  /// Fixed height; null fills the parent (full-screen maps).
  final double? height;
  final bool showLegend;
  final bool showControls;
  final bool showRouteLine;

  const DeliveryMap({
    super.key,
    this.branch,
    this.branchLabel = 'Branch',
    this.stops = const [],
    this.driver,
    this.driverLabel = 'Driver',
    this.drivers = const [],
    this.branches = const [],
    this.pin,
    this.pinLabel = 'Customer pin',
    this.height = 220,
    this.showLegend = true,
    this.showControls = true,
    this.showRouteLine = true,
  });

  /// Builds a point only when both coordinates exist and are plausible
  /// (not 0,0, inside the world's range). See [GeoUtils.isValidPin].
  static LatLng? point(num? lat, num? lng) {
    if (!GeoUtils.isValidPin(lat, lng)) return null;
    return LatLng(lat!.toDouble(), lng!.toDouble());
  }

  static bool _valid(LatLng? p) => p != null && GeoUtils.isValidPin(p.latitude, p.longitude);

  @override
  State<DeliveryMap> createState() => _DeliveryMapState();
}

class _DeliveryMapState extends State<DeliveryMap> {
  final MapController _controller = MapController();
  bool _ready = false;

  LatLng? get _branch => DeliveryMap._valid(widget.branch) ? widget.branch : null;
  LatLng? get _pin => DeliveryMap._valid(widget.pin) ? widget.pin : null;
  LatLng? get _driver => DeliveryMap._valid(widget.driver) ? widget.driver : null;
  List<MapStop> get _stops => [for (final s in widget.stops) if (DeliveryMap._valid(s.point)) s];
  List<MapDriver> get _drivers => [for (final d in widget.drivers) if (DeliveryMap._valid(d.point)) d];
  List<MapBranch> get _branches => [for (final b in widget.branches) if (DeliveryMap._valid(b.point)) b];

  List<LatLng> get _allPoints => [
        ?_branch,
        ..._branches.map((b) => b.point),
        ?_pin,
        ..._stops.map((s) => s.point),
        ?_driver,
        ..._drivers.map((d) => d.point),
      ];

  /// The points the camera is fitted to (drivers move, so they don't refit).
  String get _signature => [
        ?_branch,
        ..._branches.map((b) => b.point),
        ?_pin,
        ..._stops.map((s) => s.point),
      ].map((p) => '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}').join('|');

  String? _lastSignature;

  @override
  void didUpdateWidget(covariant DeliveryMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sig = _signature;
    if (_ready && _lastSignature != null && sig != _lastSignature) {
      _lastSignature = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fit() {
    if (!_ready) return;
    final points = _allPoints;
    if (points.isEmpty) return;
    if (points.length == 1) {
      _controller.move(points.first, 15);
    } else {
      _controller.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(40),
        maxZoom: 16,
      ));
    }
  }

  void _zoom(double by) {
    if (!_ready) return;
    final camera = _controller.camera;
    _controller.move(camera.center, (camera.zoom + by).clamp(3.0, 19.0));
  }

  @override
  Widget build(BuildContext context) {
    final points = _allPoints;
    if (points.isEmpty) return const SizedBox.shrink();
    _lastSignature ??= _signature;

    final branch = _branch;
    final pin = _pin;
    final driver = _driver;
    final stops = _stops;
    final drivers = _drivers;
    final branches = _branches;
    final route = [?branch, ...stops.where((s) => !s.faded).map((s) => s.point)];
    const interaction = InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate);
    final options = points.length >= 2
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: const EdgeInsets.all(40),
              maxZoom: 16,
            ),
            interactionOptions: interaction,
            onMapReady: () => _ready = true,
          )
        : MapOptions(
            initialCenter: points.first,
            initialZoom: 15,
            interactionOptions: interaction,
            onMapReady: () => _ready = true,
          );

    final map = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _controller,
              options: options,
              children: [
                if (MapTiles.enabled) MapTiles.tileLayer() else const SizedBox.expand(child: ColoredBox(color: AppColors.surfaceContainer)),
                if (widget.showRouteLine && route.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(points: route, strokeWidth: 3, color: AppColors.primary.withValues(alpha: 0.6)),
                  ]),
                MarkerLayer(markers: [
                  if (branch != null)
                    Marker(
                      point: branch,
                      width: 36,
                      height: 36,
                      child: Tooltip(
                        message: widget.branchLabel,
                        child: _MapPin(icon: MapMarkerStyle.branchIcon, color: MapMarkerStyle.branch),
                      ),
                    ),
                  for (final b in branches)
                    Marker(
                      point: b.point,
                      width: 36,
                      height: 36,
                      child: Tooltip(
                        message: b.label,
                        child: _MapPin(icon: MapMarkerStyle.branchIcon, color: MapMarkerStyle.branch),
                      ),
                    ),
                  if (pin != null)
                    Marker(
                      point: pin,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: Tooltip(
                        message: widget.pinLabel,
                        child: const Icon(MapMarkerStyle.customerPinIcon, size: 44, color: MapMarkerStyle.customerPin,
                            shadows: [Shadow(color: Colors.black38, blurRadius: 4)]),
                      ),
                    ),
                  for (var i = 0; i < stops.length; i++)
                    Marker(
                      point: stops[i].point,
                      width: stops[i].current ? 38 : 30,
                      height: stops[i].current ? 38 : 30,
                      child: GestureDetector(
                        onTap: stops[i].onTap,
                        child: Tooltip(
                          message: stops[i].label,
                          child: _NumberedPin(
                            text: stops[i].faded ? '+' : '${stops[i].number ?? i + 1}',
                            color: stops[i].faded
                                ? MapMarkerStyle.candidate
                                : stops[i].failed
                                    ? MapMarkerStyle.failed
                                    : (stops[i].done
                                        ? MapMarkerStyle.delivered
                                        : (stops[i].current ? MapMarkerStyle.currentStop : MapMarkerStyle.stop)),
                            highlighted: stops[i].current,
                          ),
                        ),
                      ),
                    ),
                  if (driver != null)
                    Marker(
                      point: driver,
                      width: 40,
                      height: 40,
                      child: Tooltip(
                        message: widget.driverLabel,
                        child: _MapPin(icon: MapMarkerStyle.driverIcon, color: MapMarkerStyle.driver),
                      ),
                    ),
                  for (final d in drivers)
                    Marker(
                      point: d.point,
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: d.onTap,
                        child: Tooltip(
                          message: d.label,
                          child: _MapPin(icon: MapMarkerStyle.driverIcon, color: MapMarkerStyle.driver),
                        ),
                      ),
                    ),
                ]),
                MapTiles.attribution(),
              ],
            ),
          ),
          if (widget.showControls)
            Positioned(
              top: 8,
              right: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MapButton(icon: Icons.add_rounded, tooltip: 'Zoom in', onTap: () => _zoom(1)),
                  const SizedBox(height: 6),
                  _MapButton(icon: Icons.remove_rounded, tooltip: 'Zoom out', onTap: () => _zoom(-1)),
                  const SizedBox(height: 6),
                  _MapButton(icon: Icons.center_focus_strong_rounded, tooltip: 'Recenter', onTap: _fit),
                ],
              ),
            ),
        ],
      ),
    );

    final legend = widget.showLegend
        ? _legendItems(branch ?? (branches.isEmpty ? null : branches.first.point), pin, stops, driver != null || drivers.isNotEmpty)
        : const <Widget>[];
    final sized = widget.height == null ? SizedBox.expand(child: map) : SizedBox(height: widget.height, child: map);
    if (legend.length < 2) return sized;
    if (widget.height == null) {
      return Column(children: [
        Expanded(child: map),
        Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 14, runSpacing: 4, children: legend)),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        sized,
        Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 14, runSpacing: 4, children: legend)),
      ],
    );
  }

  List<Widget> _legendItems(LatLng? branch, LatLng? pin, List<MapStop> stops, bool hasDriver) => [
        if (branch != null) const MapLegendItem(color: MapMarkerStyle.branch, label: 'Branch'),
        if (pin != null) const MapLegendItem(color: MapMarkerStyle.customerPin, label: 'Customer pin'),
        if (stops.any((s) => !s.done && !s.failed && !s.current && !s.faded))
          const MapLegendItem(color: MapMarkerStyle.stop, label: 'Stop'),
        if (stops.any((s) => s.faded)) const MapLegendItem(color: MapMarkerStyle.candidate, label: 'Not on this run'),
        if (stops.any((s) => s.current && !s.done && !s.failed))
          const MapLegendItem(color: MapMarkerStyle.currentStop, label: 'Next stop'),
        if (stops.any((s) => s.done && !s.failed)) const MapLegendItem(color: MapMarkerStyle.delivered, label: 'Delivered'),
        if (stops.any((s) => s.failed)) const MapLegendItem(color: MapMarkerStyle.failed, label: 'Failed'),
        if (hasDriver) const MapLegendItem(color: MapMarkerStyle.driver, label: 'Driver'),
      ];
}

/// One legend entry (colored dot + label).
class MapLegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const MapLegendItem({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: AppTextStyles.bodySm),
        ],
      );
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18, color: AppColors.darkBrown)),
          ),
        ),
      );
}

class _MapPin extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _MapPin({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      );
}

class _NumberedPin extends StatelessWidget {
  final String text;
  final Color color;
  final bool highlighted;
  const _NumberedPin({required this.text, required this.color, this.highlighted = false});

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: highlighted ? AppColors.darkBrown : Colors.white, width: highlighted ? 3 : 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
        ),
        child: Text(text, style: AppTextStyles.labelMd.copyWith(color: Colors.white)),
      );
}
