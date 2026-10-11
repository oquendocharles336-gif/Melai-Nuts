import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/device_location.dart';
import '../services/permission_service.dart';
import '../services/geocoding_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/geo_utils.dart';
import 'delivery_map.dart';
import 'primary_button.dart';

/// What the customer confirmed on the [LocationPickerScreen].
class PickedLocation {
  final double latitude;
  final double longitude;

  /// The address under the pin, when it could be looked up (optional: the
  /// pin is valid without it).
  final AddressSuggestion? address;

  const PickedLocation({required this.latitude, required this.longitude, this.address});
}

/// Full-screen map to pin a delivery location exactly.
///
/// * The pin is the fixed marker in the middle: drag the map under it, or tap
///   a spot to move it there.
/// * "Use my current location" reads the GPS once (never tracked). If
///   permission is refused the customer is told why and simply places the pin
///   by hand.
/// * Optional address search / reverse lookup (Nominatim). If it fails or
///   the phone is offline, the pin still works.
/// * Opens on the existing pin, else on the customer's position, else on the
///   branch, else on the Philippines — never on 0,0.
class LocationPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;

  /// Where to start when there is no pin and no GPS fix (e.g. the branch).
  final double? fallbackLatitude;
  final double? fallbackLongitude;

  /// Try the GPS once when the screen opens without an existing pin.
  final bool locateOnOpen;
  final String title;

  /// Injected in tests; defaults to [DeviceLocation.current].
  final Future<DeviceLocationResult> Function()? locate;

  /// Injected in tests; defaults to [NominatimGeocoder]. Pass
  /// [LocationPickerScreen.noGeocoder] to turn lookups off.
  final Geocoder? geocoder;
  final bool useGeocoder;

  const LocationPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
    this.fallbackLatitude,
    this.fallbackLongitude,
    this.locateOnOpen = true,
    this.title = 'Pin delivery location',
    this.locate,
    this.geocoder,
    this.useGeocoder = true,
  });

  /// Opens the picker and returns the confirmed pin (null when cancelled).
  static Future<PickedLocation?> open(
    BuildContext context, {
    double? initialLatitude,
    double? initialLongitude,
    double? fallbackLatitude,
    double? fallbackLongitude,
    String title = 'Pin delivery location',
  }) {
    return Navigator.of(context).push<PickedLocation>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => LocationPickerScreen(
        initialLatitude: initialLatitude,
        initialLongitude: initialLongitude,
        fallbackLatitude: fallbackLatitude,
        fallbackLongitude: fallbackLongitude,
        title: title,
      ),
    ));
  }

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _controller = MapController();
  final TextEditingController _search = TextEditingController();
  late final Geocoder? _geocoder = widget.useGeocoder ? (widget.geocoder ?? NominatimGeocoder()) : null;

  late LatLng _center;
  late final bool _hadPin;

  /// True once the pin reflects a real choice (existing pin, GPS, a tap, a
  /// search result or a drag). The default view of the whole country is not
  /// a delivery location, so it cannot be confirmed.
  bool _chosen = false;
  bool _ready = false;
  bool _locating = false;
  bool _confirming = false;
  bool _searching = false;
  String? _problem;
  bool _problemNeedsSettings = false;
  List<AddressSuggestion> _results = const [];
  Timer? _debounce;
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    final initial = DeliveryMap.point(widget.initialLatitude, widget.initialLongitude);
    final fallback = DeliveryMap.point(widget.fallbackLatitude, widget.fallbackLongitude);
    _hadPin = initial != null;
    _chosen = _hadPin;
    _center = initial ?? fallback ?? const LatLng(GeoUtils.philippinesLat, GeoUtils.philippinesLng);
    if (!_hadPin && widget.locateOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _useMyLocation(quiet: true));
    }
  }

  double get _initialZoom {
    if (_hadPin) return 17;
    if (DeliveryMap.point(widget.fallbackLatitude, widget.fallbackLongitude) != null) return 14;
    return 5;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// A move asked for before the map finished its first layout.
  LatLng? _pendingMove;

  void _onMapReady() {
    _ready = true;
    final pending = _pendingMove;
    if (pending != null) {
      _pendingMove = null;
      _controller.move(pending, 17);
    }
  }

  void _moveTo(LatLng p, {double? zoom}) {
    _center = p;
    _chosen = true;
    if (_ready) {
      _controller.move(p, zoom ?? (_controller.camera.zoom < 16 ? 17 : _controller.camera.zoom));
    } else {
      _pendingMove = p;
    }
    setState(() {});
  }

  /// The map reports every camera change; the pin is the camera's center.
  /// Rebuilt after the frame (never during the map's own build).
  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _center = camera.center;
    if (hasGesture) _chosen = true;
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _useMyLocation({bool quiet = false}) async {
    if (_locating) return;
    setState(() {
      _locating = true;
      if (!quiet) _problem = null;
    });
    if (widget.locate == null && DeviceLocation.supported) {
      final permissions = PermissionService.instance;
      if (quiet) {
        // Opening the picker never triggers a permission prompt: centre on the
        // person only when location was already allowed.
        if (!await permissions.locationGranted()) {
          if (mounted) setState(() => _locating = false);
          return;
        }
      } else {
        // "Use my location" tapped: explain first, then ask.
        final outcome = await permissions.requestLocation(context, PermissionPurpose.pinAddress);
        if (!mounted) return;
        if (outcome == PermissionOutcome.denied || outcome == PermissionOutcome.permanentlyDenied) {
          setState(() {
            _locating = false;
            _problem = 'Location permission was not given. You can still move the map to place the pin by hand.';
            _problemNeedsSettings = outcome == PermissionOutcome.permanentlyDenied;
          });
          return;
        }
      }
    }
    final result = await (widget.locate ?? DeviceLocation.current)();
    if (!mounted) return;
    setState(() => _locating = false);
    if (result.ok && GeoUtils.isValidPin(result.latitude, result.longitude)) {
      setState(() {
        _problem = null;
        _problemNeedsSettings = false;
      });
      _moveTo(LatLng(result.latitude!, result.longitude!), zoom: 17);
    } else if (!quiet || result.needsSettings) {
      setState(() {
        _problem = result.problem ?? 'Your location could not be read. Move the map to place the pin by hand.';
        _problemNeedsSettings = result.needsSettings;
      });
    }
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    final g = _geocoder;
    if (g == null) return;
    if (text.trim().length < 3) {
      setState(() => _results = const []);
      return;
    }
    // Nominatim allows about one request per second: wait until typing stops.
    _debounce = Timer(const Duration(milliseconds: 700), () async {
      setState(() => _searching = true);
      final found = await g.search(text);
      if (!mounted) return;
      if (_search.text != text) {
        setState(() => _searching = false); // a newer search is on its way
        return;
      }
      setState(() {
        _searching = false;
        _results = found;
      });
      if (found.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No matching place found (or search is unavailable). You can still move the map to place the pin.'),
        ));
      }
    });
  }

  void _pickResult(AddressSuggestion s) {
    FocusScope.of(context).unfocus();
    setState(() => _results = const []);
    _moveTo(LatLng(s.latitude, s.longitude), zoom: 17);
  }

  Future<void> _confirm() async {
    if (!_chosen || !GeoUtils.isValidPin(_center.latitude, _center.longitude)) return;
    final lat = _center.latitude;
    final lng = _center.longitude;
    setState(() => _confirming = true);
    AddressSuggestion? address;
    final g = _geocoder;
    if (g != null) {
      // Optional: prefill the address form. A failure just means no prefill.
      address = await g.reverse(lat, lng);
    }
    if (!mounted) return;
    Navigator.of(context).pop(PickedLocation(latitude: lat, longitude: lng, address: address));
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = _chosen && GeoUtils.isValidPin(_center.latitude, _center.longitude);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (_geocoder != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search a street, barangay or landmark',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                ),
              ),
            ),
          if (_results.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: Material(
                color: Colors.white,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _results)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined),
                        title: Text(r.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => _pickResult(r),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: FlutterMap(
                    mapController: _controller,
                    options: MapOptions(
                      initialCenter: _center,
                      initialZoom: _initialZoom,
                      interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                      onMapReady: _onMapReady,
                      onTap: (_, point) => _moveTo(point),
                      onPositionChanged: _onPositionChanged,
                    ),
                    children: [
                      if (MapTiles.enabled)
                        MapTiles.tileLayer()
                      else
                        const SizedBox.expand(child: ColoredBox(color: AppColors.surfaceContainer)),
                      MapTiles.attribution(),
                    ],
                  ),
                ),
                // The pin: its tip is exactly the map's center.
                const IgnorePointer(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 44),
                      child: Icon(MapMarkerStyle.customerPinIcon, size: 48, color: MapMarkerStyle.customerPin,
                          shadows: [Shadow(color: Colors.black38, blurRadius: 6)]),
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: FloatingActionButton.small(
                    heroTag: 'pin-my-location',
                    tooltip: 'Use my current location',
                    onPressed: _locating ? null : () => _useMyLocation(),
                    child: _locating
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location_rounded),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    canConfirm
                        ? 'Pin at ${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}'
                        : 'Move the map (or tap) so the pin sits on your gate or door.',
                    style: AppTextStyles.labelLg,
                  ),
                  const SizedBox(height: 2),
                  Text('Drag the map under the pin, or tap the exact spot.', style: AppTextStyles.bodySm),
                  if (_problem != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppSpacing.radiusSm)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_problem!, style: AppTextStyles.bodySm),
                          if (_problemNeedsSettings)
                            TextButton(
                              onPressed: () => DeviceLocation.openSettings(),
                              child: const Text('Open settings'),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: _locating ? null : () => _useMyLocation(),
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('Use my current location'),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  PrimaryButton(
                    label: 'Confirm pin',
                    icon: Icons.check_rounded,
                    loading: _confirming,
                    onPressed: canConfirm ? _confirm : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
