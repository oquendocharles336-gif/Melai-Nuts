import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/app_error.dart';

/// Result of asking the device for its position once.
class DeviceLocationResult {
  final double? latitude;
  final double? longitude;

  /// Plain-words reason when no position could be read (null on success).
  final String? problem;

  /// True when the customer must change a setting themselves (permission
  /// blocked for good, or location services off): offer "Open settings".
  final bool needsSettings;

  const DeviceLocationResult._({this.latitude, this.longitude, this.problem, this.needsSettings = false});

  const DeviceLocationResult.found(double latitude, double longitude)
      : this._(latitude: latitude, longitude: longitude);

  const DeviceLocationResult.failed(String problem, {bool needsSettings = false})
      : this._(problem: problem, needsSettings: needsSettings);

  bool get ok => latitude != null && longitude != null;
}

/// Reads the device's position ONCE, when the person asks (a "use my current
/// location" button). Nothing is tracked, repeated or stored.
///
/// geolocator has no Linux implementation, so on Linux (and any platform it
/// does not support) this answers with a friendly problem instead of throwing:
/// the pin can always be placed by hand on the map.
class DeviceLocation {
  DeviceLocation._();

  static bool get supported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  static Future<DeviceLocationResult> current({Duration timeout = const Duration(seconds: 20)}) async {
    if (!supported) {
      return const DeviceLocationResult.failed(
          'This device cannot share its location here. Move the map to place the pin by hand.');
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const DeviceLocationResult.failed(
            'Location is turned off on this device. Turn it on, or move the map to place the pin by hand.',
            needsSettings: true);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return const DeviceLocationResult.failed(
            'Location permission is blocked for Melai Nuts. Allow it in Settings, or move the map to place the pin by hand.',
            needsSettings: true);
      }
      if (permission == LocationPermission.denied) {
        return const DeviceLocationResult.failed(
            'Location permission was not given. You can still move the map to place the pin by hand.');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(timeout);
      return DeviceLocationResult.found(pos.latitude, pos.longitude);
    } on TimeoutException {
      return const DeviceLocationResult.failed(
          'Your location took too long to read. Try again near a window, or place the pin by hand.');
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'device_location:83');
      return const DeviceLocationResult.failed(
          'Your location could not be read. Move the map to place the pin by hand.');
    }
  }

  /// Opens the app's settings page (permission blocked) or the device's
  /// location settings (services off). Quietly does nothing where unsupported.
  static Future<void> openSettings({bool locationServices = false}) async {
    if (!supported) return;
    try {
      if (locationServices) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'device_location:99');
    }
  }
}
