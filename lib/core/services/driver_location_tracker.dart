import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/repositories/driver_repository.dart';
import '../utils/app_error.dart';

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
/// Screen off / app in the background: on Android a FOREGROUND SERVICE keeps
/// sharing, with a permanent "Sharing your delivery location" notification
/// (no ACCESS_BACKGROUND_LOCATION needed: the service is started while the
/// app is open); on iOS the location background mode shows the blue status-bar
/// indicator. Both stop with the run. The driver sees a rationale first
/// ([backgroundRationale], driver portal) — required for store review.
/// See docs/DRIVER_LOCATION.md.
class DriverLocationTracker extends ChangeNotifier {
  DriverLocationTracker._();
  static final DriverLocationTracker instance = DriverLocationTracker._();

  static const Duration minInterval = Duration(seconds: 15);
  static const int distanceFilterMeters = 20;

  /// Shown to the driver before sharing starts (Play / App Store policy:
  /// explain prominently why the position is used and when it stops).
  static const String backgroundRationale =
      'While this run is out, Melai Nuts shares your position with your branch and the customers on '
      'this run — also when the screen is off or you use another app (a notification shows it is on). '
      'It stops by itself when the run is delivered, failed or cancelled, and you can stop it any time '
      'here. Your position is not stored on the phone, and the server deletes it when the run ends.';

  /// Platform settings: a foreground service on Android, background updates
  /// with the indicator on iOS.
  static LocationSettings settingsFor(TargetPlatform platform, {bool isWeb = false}) {
    if (isWeb) {
      return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: distanceFilterMeters);
    }
    switch (platform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
          intervalDuration: minInterval,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Sharing your delivery location',
            notificationText: 'Only for this run. It stops when the run ends.',
            notificationChannelName: 'Delivery location',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilterMeters,
          activityType: ActivityType.automotiveNavigation,
          pauseLocationUpdatesAutomatically: true,
          allowBackgroundLocationUpdates: true,
          showBackgroundLocationIndicator: true,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: distanceFilterMeters);
    }
  }

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
      locationSettings: settingsFor(defaultTargetPlatform, isWeb: kIsWeb),
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
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'driver_location_tracker:106');
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
