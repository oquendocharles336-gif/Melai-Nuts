import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/repositories/driver_repository.dart';

/// Shares the driver's position for ONE delivery run while the app is open.
///
/// Privacy rules (the database enforces the same ones):
///  * only after the driver turns sharing on for a run they have picked up;
///  * at most one point every [minInterval] and only after moving
///    [distanceFilterMeters];
///  * stops by itself as soon as the server answers `tracking: false`
///    (run delivered, failed or cancelled), or when [stop] is called;
///  * nothing is stored on the phone.
///
/// Background tracking (screen off / app closed) is not enabled: it needs a
/// foreground service on Android and background modes on iOS, plus a store
/// review justification. See docs/ROADMAP.md.
class DriverLocationTracker extends ChangeNotifier {
  DriverLocationTracker._();
  static final DriverLocationTracker instance = DriverLocationTracker._();

  static const Duration minInterval = Duration(seconds: 15);
  static const int distanceFilterMeters = 20;

  StreamSubscription<Position>? _sub;
  String? _deliveryId;
  DateTime? _lastSent;
  String? _problem;

  /// The run currently being shared, or null.
  String? get deliveryId => _deliveryId;
  bool get isSharing => _deliveryId != null;

  /// Why sharing could not start / stopped, in plain words (null when fine).
  String? get problem => _problem;

  /// The last position read while sharing (for the driver's own map); null
  /// when not sharing. Never stored.
  Position? _last;
  Position? get lastPosition => _last;

  /// Asks for permission if needed and starts sharing. Returns false (and sets
  /// [problem]) when location is off or permission was refused.
  Future<bool> start(String deliveryId) async {
    if (_deliveryId == deliveryId) return true;
    await stop();
    _problem = null;

    if (!await Geolocator.isLocationServiceEnabled()) {
      _problem = 'Location is turned off on this phone. Turn it on to share your position.';
      notifyListeners();
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _problem = permission == LocationPermission.deniedForever
          ? 'Location permission is blocked. Allow it in the phone settings to share your position.'
          : 'Location permission was not given, so your position is not shared.';
      notifyListeners();
      return false;
    }

    _deliveryId = deliveryId;
    _lastSent = null;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    ).listen(_onPosition, onError: (Object e) {
      _problem = 'Your position could not be read. Sharing has stopped.';
      stop();
    });
    notifyListeners();
    return true;
  }

  Future<void> _onPosition(Position p) async {
    final id = _deliveryId;
    if (id == null) return;
    _last = p;
    notifyListeners();
    final now = DateTime.now();
    if (_lastSent != null && now.difference(_lastSent!) < minInterval) return;
    _lastSent = now;
    try {
      final ack = await DriverRepository.instance.postLocation(
        deliveryId: id,
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyM: p.accuracy,
        recordedAt: p.timestamp,
        heading: p.heading >= 0 ? p.heading : null,
        speedMps: p.speed >= 0 ? p.speed : null,
      );
      if (!ack.tracking) {
        // The run is over (or not picked up): the server no longer wants points.
        await stop();
      }
    } catch (_) {
      // A dropped point is fine; the next one will be sent. Keep sharing.
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final had = _deliveryId != null;
    _deliveryId = null;
    _lastSent = null;
    _last = null;
    if (had) notifyListeners();
  }
}
