import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/repositories/route_eta_repository.dart';

void main() {
  test('road distance and time are read and labelled as an estimate', () {
    final eta = RoadEta.fromJson({'total_distance_m': 8123, 'total_duration_s': 901, 'estimate': true});
    expect(eta, isNotNull);
    expect(eta!.label, '8.1 km by road · about 16 min (estimate)');
    expect(RoadEta.fromJson({'total_distance_m': 50000, 'total_duration_s': 4000})!.label, contains('1 h 7 min'));
  });

  test('no usable answer gives no figure (never a made-up one)', () {
    expect(RoadEta.fromJson(null), isNull);
    expect(RoadEta.fromJson({'error': 'Road distance is not configured.'}), isNull);
    expect(RoadEta.fromJson({'total_distance_m': 0, 'total_duration_s': 0}), isNull);
  });
}
