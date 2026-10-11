// Delivery pins and maps (customer pin, rider stop pins, staff order pin).
//
// Pure rules (pin validation, the checkout gate, navigation links, distance,
// geocoder parsing) plus widget checks with map tiles turned off (no network
// in tests): a stop without coordinates shows the "call them" fallback, the
// map picker returns the confirmed coordinates, and the staff order card shows
// a map only when the customer pinned the location.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/device_location.dart';
import 'package:melai_nuts/core/services/geocoding_service.dart';
import 'package:melai_nuts/core/utils/geo_utils.dart';
import 'package:melai_nuts/core/widgets/delivery_map.dart';
import 'package:melai_nuts/core/widgets/location_picker.dart';
import 'package:melai_nuts/data/models/delivery.dart';
import 'package:melai_nuts/data/repositories/delivery_repository.dart';
import 'package:melai_nuts/features/delivery/widgets/run_map_card.dart';
import 'package:melai_nuts/features/staff/screens/staff_transactions_screen.dart';

DeliveryStop _stop({String id = 's1', double? lat, double? lng, StopStatus status = StopStatus.pending, int seq = 0, String? phone = '09170000001'}) =>
    DeliveryStop(
      id: id,
      customerName: 'Pia Pinned',
      address: '7 Pin St, Calamba',
      orderId: 'ORD-$id',
      items: const ['1x Garlic Peanuts'],
      sequenceIndex: seq,
      distanceFromPreviousKm: 1.2,
      travelMinutesFromPrevious: 5,
      eta: '10:30 AM',
      status: status,
      latitude: lat,
      longitude: lng,
      contactPhone: phone,
    );

Delivery _run(List<DeliveryStop> stops, {DeliveryStatus status = DeliveryStatus.dispatched}) => Delivery(
      id: 'DEL-1',
      branch: 'Calamba',
      vehicle: 'Motorbike',
      riderName: 'Rider',
      createdAt: DateTime(2026, 10, 11),
      stops: stops,
      status: status,
      branchLatitude: 14.2117,
      branchLongitude: 121.1653,
    );

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

/// Button finders that also match the `.icon` variants (they are subclasses).
Finder _buttonWithText<T extends Widget>(String text) =>
    find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => w is T)).first;

ElevatedButton _confirmButton(WidgetTester tester) => tester.widget<ElevatedButton>(_buttonWithText<ElevatedButton>('Confirm pin'));

class _NoGeocoder implements Geocoder {
  @override
  Future<AddressSuggestion?> reverse(double latitude, double longitude) async => null;
  @override
  Future<List<AddressSuggestion>> search(String query) async => const [];
}

void main() {
  setUp(() => MapTiles.enabled = false);
  tearDown(() => MapTiles.enabled = true);

  group('pin validation (GeoUtils.isValidPin / DeliveryMap.point)', () {
    test('a real pin is valid', () {
      expect(GeoUtils.isValidPin(14.20501, 121.15602), isTrue);
      expect(DeliveryMap.point(14.20501, 121.15602)?.latitude, 14.20501);
    });
    test('missing coordinates are not a pin', () {
      expect(DeliveryMap.point(null, 121.1), isNull);
      expect(DeliveryMap.point(14.2, null), isNull);
      expect(DeliveryMap.point(null, null), isNull);
    });
    test('0,0 (a failed GPS fix) is never a pin', () {
      expect(GeoUtils.isValidPin(0, 0), isFalse);
      expect(DeliveryMap.point(0, 0), isNull);
      expect(DeliveryMap.point(0.0, 0.0), isNull);
      // one coordinate at 0 alone is a real place
      expect(GeoUtils.isValidPin(0, 121.1), isTrue);
    });
    test('out-of-range and non-numbers are refused', () {
      expect(DeliveryMap.point(91, 121), isNull);
      expect(DeliveryMap.point(-90.5, 121), isNull);
      expect(DeliveryMap.point(14, 181), isNull);
      expect(DeliveryMap.point(14, -180.01), isNull);
      expect(GeoUtils.isValidPin(double.nan, 121), isFalse);
      expect(GeoUtils.isValidPin(14, double.infinity), isFalse);
      expect(DeliveryMap.point(90, 180), isNotNull); // the edges are inside the world
    });
  });

  group('checkout pin gate', () {
    test('pickup orders never need a pin', () {
      expect(GeoUtils.deliveryPinProblem(isDelivery: false), isNull);
    });
    test('a delivery order without a valid pin is blocked with a clear message', () {
      expect(GeoUtils.deliveryPinProblem(isDelivery: true), contains('Pin your delivery location'));
      expect(GeoUtils.deliveryPinProblem(isDelivery: true, lat: 0, lng: 0), isNotNull);
      expect(GeoUtils.deliveryPinProblem(isDelivery: true, lat: 95, lng: 121), isNotNull);
    });
    test('a delivery order with a valid pin may be placed', () {
      expect(GeoUtils.deliveryPinProblem(isDelivery: true, lat: 14.205, lng: 121.156), isNull);
    });
    test('a pin far from the branch is warned about, not blocked', () {
      expect(GeoUtils.farFromBranchWarning(lat: 14.205, lng: 121.156, branchLat: 14.2117, branchLng: 121.1653), isNull);
      expect(
        GeoUtils.farFromBranchWarning(lat: 10.3157, lng: 123.8854, branchLat: 14.2117, branchLng: 121.1653, branchName: 'Calamba'),
        contains('from Calamba'),
      );
      expect(GeoUtils.farFromBranchWarning(lat: 10.3, lng: 123.8), isNull); // branch position unknown
    });
  });

  group('distance', () {
    test('Calamba to Los Baños is about 9 km', () {
      final km = GeoUtils.distanceKm(14.2117, 121.1653, 14.1651, 121.2413);
      expect(km, greaterThan(8));
      expect(km, lessThan(10.5));
    });
    test('formatting', () {
      expect(GeoUtils.formatDistance(0.85), '850 m');
      expect(GeoUtils.formatDistance(3.42), '3.4 km');
      expect(GeoUtils.formatDistance(25.4), '25 km');
    });
  });

  group('navigation links', () {
    test('a pinned stop navigates to the exact coordinates in every app', () {
      final g = NavigationLinks.googleMaps(lat: 14.205, lng: 121.156, address: '7 Pin St')!;
      expect(g.host, 'www.google.com');
      expect(g.queryParameters['destination'], '14.205,121.156');
      expect(g.queryParameters['travelmode'], 'driving');
      final w = NavigationLinks.waze(lat: 14.205, lng: 121.156)!;
      expect(w.host, 'waze.com');
      expect(w.queryParameters['ll'], '14.205,121.156');
      expect(w.queryParameters['navigate'], 'yes');
      final a = NavigationLinks.appleMaps(lat: 14.205, lng: 121.156)!;
      expect(a.host, 'maps.apple.com');
      expect(a.queryParameters['daddr'], '14.205,121.156');
    });
    test('without a valid pin the address text is used', () {
      final g = NavigationLinks.googleMaps(lat: 0, lng: 0, address: '7 Pin St, Calamba')!;
      expect(g.queryParameters['destination'], '7 Pin St, Calamba');
      expect(NavigationLinks.waze(address: '7 Pin St')!.queryParameters['q'], '7 Pin St');
    });
    test('nothing to navigate to gives no link', () {
      expect(NavigationLinks.googleMaps(), isNull);
      expect(NavigationLinks.forDestination(address: '  '), isEmpty);
      expect(NavigationLinks.forDestination(lat: 14.205, lng: 121.156).map((t) => t.label),
          ['Google Maps', 'Waze', 'Apple Maps']);
    });
  });

  group('geocoder parsing (Nominatim)', () {
    test('maps a Philippine address into the form fields', () {
      final s = NominatimGeocoder.parseResult({
        'lat': '14.2050',
        'lon': '121.1560',
        'display_name': '7, Rizal Street, Barangay Uno, Calamba, Laguna, 4027, Philippines',
        'address': {
          'house_number': '7',
          'road': 'Rizal Street',
          'quarter': 'Barangay Uno',
          'city': 'Calamba',
          'state': 'Laguna',
          'postcode': '4027',
        },
      })!;
      expect(s.line1, '7 Rizal Street, Barangay Uno');
      expect(s.city, 'Calamba');
      expect(s.province, 'Laguna');
      expect(s.postalCode, '4027');
      expect(s.latitude, closeTo(14.205, 1e-9));
    });
    test('a result without usable coordinates is dropped', () {
      expect(NominatimGeocoder.parseResult({'lat': '0', 'lon': '0'}), isNull);
      expect(NominatimGeocoder.parseResult({'display_name': 'x'}), isNull);
    });
  });

  group('rider stop pins', () {
    test('the current stop is the first unfinished one, and only pinned stops are drawn', () {
      final run = _run([
        _stop(id: 'a', lat: 14.20, lng: 121.15, status: StopStatus.delivered, seq: 0),
        _stop(id: 'b', lat: 14.21, lng: 121.16, seq: 1),
        _stop(id: 'c', seq: 2), // not pinned
      ]);
      expect(RunMap.currentStop(run)?.id, 'b');
      final stops = RunMap.mapStops(run);
      expect(stops.length, 2);
      expect(stops.firstWhere((s) => s.current).number, 2);
      expect(stops.firstWhere((s) => s.done).number, 1);
      expect(RunMap.unpinnedOpenStops(run).map((s) => s.id), ['c']);
    });

    testWidgets('a stop with no coordinates shows the address and a "call them" notice, not an empty map', (tester) async {
      final stop = _stop(lat: null, lng: null);
      final run = _run([stop]);
      await tester.pumpWidget(_app(Column(children: [
        RunMapCard(delivery: run),
        StopNavigationActions(delivery: run, stop: stop),
      ])));
      expect(find.textContaining("Customer didn't pin a location"), findsOneWidget);
      expect(find.text('Navigate (address)'), findsOneWidget);
      expect(find.text('Call customer'), findsOneWidget);
      // The branch is still shown, but no stop marker is invented.
      expect(find.text('1'), findsNothing);
    });

    testWidgets('a pinned stop gets Navigate and Call while the run is active', (tester) async {
      final stop = _stop(lat: 14.205, lng: 121.156);
      final run = _run([stop]);
      await tester.pumpWidget(_app(StopNavigationActions(delivery: run, stop: stop)));
      expect(find.text('Navigate'), findsOneWidget);
      expect(find.text('Call customer'), findsOneWidget);
      expect(find.textContaining("didn't pin"), findsNothing);
    });

    testWidgets('after the run ends there is nothing to navigate to (address and pin are hidden)', (tester) async {
      final stop = _stop(lat: null, lng: null, status: StopStatus.delivered, phone: null);
      final run = _run([stop], status: DeliveryStatus.completed);
      await tester.pumpWidget(_app(StopNavigationActions(delivery: run, stop: stop)));
      expect(find.byWidgetPredicate((w) => w is OutlinedButton || w is FilledButton), findsNothing);
    });
  });

  group('customer map picker', () {
    testWidgets('returns the coordinates the customer confirmed', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      PickedLocation? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<PickedLocation>(MaterialPageRoute(
                    builder: (_) => LocationPickerScreen(
                      locateOnOpen: false,
                      fallbackLatitude: 14.2117,
                      fallbackLongitude: 121.1653,
                      locate: () async => const DeviceLocationResult.found(14.20501, 121.15602),
                      geocoder: _NoGeocoder(),
                    ),
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Nothing chosen yet: the branch view is not a delivery location.
      expect(_confirmButton(tester).onPressed, isNull);

      await tester.tap(find.text('Use my current location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('14.20501, 121.15602'), findsOneWidget);

      expect(_confirmButton(tester).onPressed, isNotNull);
      await tester.tap(find.text('Confirm pin'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.latitude, closeTo(14.20501, 1e-6));
      expect(result!.longitude, closeTo(121.15602, 1e-6));
    });

    testWidgets('permission refused: explains it and the pin can still be placed by hand', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        home: LocationPickerScreen(
          locateOnOpen: false,
          initialLatitude: 14.2,
          initialLongitude: 121.1,
          locate: () async => const DeviceLocationResult.failed('Location permission is blocked for Melai Nuts.', needsSettings: true),
          useGeocoder: false,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my current location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('permission is blocked'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      // The existing pin can still be confirmed.
      expect(_confirmButton(tester).onPressed, isNotNull);
    });
  });

  group('staff order details', () {
    testWidgets('shows the customer pin on a map when there is one', (tester) async {
      await tester.pumpWidget(_app(const DeliveryPinCard(
        pin: OrderDeliveryPin(
          orderId: 'ORD-1',
          branchName: 'Calamba',
          branchLatitude: 14.2117,
          branchLongitude: 121.1653,
          address: '7 Pin St, Calamba',
          recipientName: 'Pia Pinned',
          contactPhone: '09170000001',
          latitude: 14.20501,
          longitude: 121.15602,
          distanceKm: 1.27,
        ),
      )));
      expect(find.byKey(const ValueKey('staff-order-pin-map')), findsOneWidget);
      expect(find.text('Open in Maps'), findsOneWidget);
      expect(find.text('1.3 km from branch'), findsOneWidget);
    });

    testWidgets('without a pin: no map, a clear notice and a call button', (tester) async {
      await tester.pumpWidget(_app(const DeliveryPinCard(
        pin: OrderDeliveryPin(orderId: 'ORD-2', address: '9 No Pin Rd', contactPhone: '09170000002'),
      )));
      expect(find.byKey(const ValueKey('staff-order-pin-map')), findsNothing);
      expect(find.textContaining("Customer didn't pin a location"), findsOneWidget);
      expect(find.text('Call customer'), findsOneWidget);
    });
  });
}
