import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/branch_controller.dart';
import 'package:melai_nuts/data/models/branch.dart';

Branch _branch(String id, {double? lat, double? lng, bool warehouse = false}) => Branch.fromRow({
      'id': id,
      'name': id,
      'address': '',
      'phone': '',
      'latitude': lat,
      'longitude': lng,
      'supports_delivery': true,
      'supports_pickup': true,
      'is_warehouse': warehouse,
    });

void main() {
  final calamba = _branch('calamba', lat: 14.2117, lng: 121.1653);
  final losBanos = _branch('los-banos', lat: 14.1699, lng: 121.2413);
  final santaCruz = _branch('santa-cruz', lat: 14.2810, lng: 121.4160);

  test('picks the closest branch', () {
    final all = [calamba, losBanos, santaCruz];
    expect(BranchController.nearestBranch(14.27, 121.40, all)!.id, 'santa-cruz');
    expect(BranchController.nearestBranch(14.20, 121.15, all)!.id, 'calamba');
  });

  test('skips branches without coordinates and warehouses', () {
    final warehouse = _branch('warehouse', lat: 14.27, lng: 121.40, warehouse: true);
    final noPin = _branch('no-pin');
    expect(BranchController.nearestBranch(14.27, 121.40, [warehouse, noPin, calamba])!.id, 'calamba');
    expect(BranchController.nearestBranch(14.27, 121.40, [noPin]), isNull);
  });
}
