import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/services/supabase_token.dart';
import '../models/delivery.dart';

/// Road distance and driving time of a run, from the `route-eta` Edge
/// Function (the routing key lives there, never in the app). Always an
/// ESTIMATE; null when the server has no routing service configured, the run
/// has no branch position, or a stop has no pin.
class RoadEta {
  final double distanceKm;
  final Duration duration;
  const RoadEta(this.distanceKm, this.duration);

  /// "8.1 km by road · about 15 min (estimate)".
  String get label {
    final minutes = (duration.inSeconds / 60).ceil();
    final time = minutes >= 60 ? '${minutes ~/ 60} h ${minutes % 60} min' : '$minutes min';
    return '${distanceKm.toStringAsFixed(1)} km by road · about $time (estimate)';
  }

  /// Parses the function's answer; null when it is not usable.
  static RoadEta? fromJson(Object? data) {
    if (data is! Map) return null;
    final m = data['total_distance_m'];
    final s = data['total_duration_s'];
    if (m is! num || s is! num || m <= 0) return null;
    return RoadEta(m / 1000, Duration(seconds: s.round()));
  }
}

class RouteEtaRepository {
  RouteEtaRepository._();
  static final RouteEtaRepository instance = RouteEtaRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<RoadEta?> forRun(Delivery d) async {
    final lat = d.branchLatitude, lng = d.branchLongitude;
    final pins = d.stops.where((s) => s.latitude != null && s.longitude != null).toList();
    if (lat == null || lng == null || pins.isEmpty || pins.length != d.stops.length) return null;
    final token = await SupabaseToken.fetch();
    if (token == null) return null;
    try {
      final res = await _client.functions.invoke(
        'route-eta',
        headers: {'Authorization': 'Bearer $token'},
        body: {
          'from': {'lat': lat, 'lng': lng},
          'stops': [for (final s in pins) {'lat': s.latitude, 'lng': s.longitude}],
        },
      );
      return RoadEta.fromJson(res.data);
    } on FunctionException {
      return null; // not configured (503) or no route: the screen shows no road figure
    }
  }
}
