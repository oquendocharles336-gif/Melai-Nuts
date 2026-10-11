import 'dart:math' as math;

/// Small, pure helpers for delivery pins (no Flutter, no plugins), so the
/// rules are the same on every screen and easy to unit test.
///
/// A delivery pin is "valid" only when both coordinates exist, are inside the
/// world's range and are not exactly 0,0 (what a broken GPS fix returns —
/// "null island", never a Melai Nuts customer). The database refuses the
/// same values (migration 20261016000000_delivery_pins_app_only.sql).
class GeoUtils {
  GeoUtils._();

  /// Where a map opens when there is nothing better: the middle of the
  /// Philippines. Only used to center an empty map picker, never shown as a
  /// pin.
  static const double philippinesLat = 12.8797;
  static const double philippinesLng = 121.7740;

  /// Beyond this distance from the branch a pin is unusual enough to warn the
  /// customer (it is not blocked: the branch decides whether it delivers).
  static const double farFromBranchKm = 30;

  static bool isValidPin(num? lat, num? lng) {
    if (lat == null || lng == null) return false;
    final la = lat.toDouble(), lo = lng.toDouble();
    if (la.isNaN || lo.isNaN || la.isInfinite || lo.isInfinite) return false;
    if (la.abs() > 90 || lo.abs() > 180) return false;
    if (la == 0 && lo == 0) return false;
    return true;
  }

  /// Great-circle distance in kilometres (haversine).
  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
    return earthKm * 2 * math.asin(math.min(1, math.sqrt(a)));
  }

  /// "850 m" / "3.4 km".
  static String formatDistance(double km) =>
      km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';

  /// Why a delivery order cannot be placed yet, or null when it can.
  /// Pickup orders never need a pin.
  static String? deliveryPinProblem({required bool isDelivery, num? lat, num? lng}) {
    if (!isDelivery) return null;
    if (!isValidPin(lat, lng)) {
      return 'Pin your delivery location on the map so the rider can find you.';
    }
    return null;
  }

  /// A friendly warning when the pin is far from the branch (null otherwise,
  /// or when either point is unknown).
  static String? farFromBranchWarning({num? lat, num? lng, num? branchLat, num? branchLng, String branchName = 'the branch'}) {
    if (!isValidPin(lat, lng) || !isValidPin(branchLat, branchLng)) return null;
    final km = distanceKm(lat!.toDouble(), lng!.toDouble(), branchLat!.toDouble(), branchLng!.toDouble());
    if (km <= farFromBranchKm) return null;
    return 'This pin is ${formatDistance(km)} from $branchName. Check it is right, or choose a nearer branch.';
  }
}

/// One way to get turn-by-turn directions to a stop.
class NavigationTarget {
  final String label;
  final Uri uri;
  const NavigationTarget(this.label, this.uri);
}

/// Deep links to the big navigation apps. All of them are plain https links
/// (no API key, no app-specific scheme): when the app is installed the phone
/// opens it, otherwise the browser does.
///
/// The pinned coordinates are used whenever they are valid; without them
/// the address text is searched instead (and may be less exact).
class NavigationLinks {
  NavigationLinks._();

  static bool _pinned(num? lat, num? lng) => GeoUtils.isValidPin(lat, lng);
  static String _ll(num lat, num lng) => '${lat.toDouble()},${lng.toDouble()}';

  static Uri? googleMaps({num? lat, num? lng, String? address}) {
    final destination = _pinned(lat, lng) ? _ll(lat!, lng!) : (address ?? '').trim();
    if (destination.isEmpty) return null;
    return Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': destination,
      'travelmode': 'driving',
    });
  }

  static Uri? waze({num? lat, num? lng, String? address}) {
    if (_pinned(lat, lng)) {
      return Uri.https('waze.com', '/ul', {'ll': _ll(lat!, lng!), 'navigate': 'yes'});
    }
    final q = (address ?? '').trim();
    if (q.isEmpty) return null;
    return Uri.https('waze.com', '/ul', {'q': q, 'navigate': 'yes'});
  }

  static Uri? appleMaps({num? lat, num? lng, String? address}) {
    final destination = _pinned(lat, lng) ? _ll(lat!, lng!) : (address ?? '').trim();
    if (destination.isEmpty) return null;
    return Uri.https('maps.apple.com', '/', {'daddr': destination, 'dirflg': 'd'});
  }

  /// A "show this point" link (no route), used by the staff "Open in Maps".
  static Uri? showOnMap({num? lat, num? lng, String? address}) {
    final query = _pinned(lat, lng) ? _ll(lat!, lng!) : (address ?? '').trim();
    if (query.isEmpty) return null;
    return Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': query});
  }

  /// Every available target, Google Maps first. Empty when there is neither a
  /// valid pin nor an address.
  static List<NavigationTarget> forDestination({num? lat, num? lng, String? address}) {
    final out = <NavigationTarget>[];
    final g = googleMaps(lat: lat, lng: lng, address: address);
    final w = waze(lat: lat, lng: lng, address: address);
    final a = appleMaps(lat: lat, lng: lng, address: address);
    if (g != null) out.add(NavigationTarget('Google Maps', g));
    if (w != null) out.add(NavigationTarget('Waze', w));
    if (a != null) out.add(NavigationTarget('Apple Maps', a));
    return out;
  }
}
