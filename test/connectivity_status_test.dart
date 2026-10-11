import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/connectivity_service.dart';

void main() {
  late StreamController<List<ConnectivityResult>> changes;
  late List<ConnectivityResult> current;
  late ConnectivityService service;

  setUp(() {
    changes = StreamController<List<ConnectivityResult>>.broadcast(sync: true);
    current = [ConnectivityResult.wifi];
    service = ConnectivityService.testing(
      check: () async => current,
      changes: () => changes.stream,
    );
  });

  tearDown(() async {
    service.dispose();
    await changes.close();
  });

  test('reports ONLINE when the platform reports a connection', () async {
    await service.start();
    expect(service.isOnline, isTrue);
    expect(service.status, ConnectionStatus.online);
  });

  test('reports OFFLINE when the platform reports no connection', () async {
    current = [ConnectivityResult.none];
    await service.start();
    expect(service.isOnline, isFalse);
    expect(service.status, ConnectionStatus.offline);
  });

  test('follows connectivity changes and notifies listeners', () async {
    await service.start();
    var notified = 0;
    service.addListener(() => notified++);

    changes.add([ConnectivityResult.none]);
    expect(service.status, ConnectionStatus.offline);
    changes.add([ConnectivityResult.mobile]);
    expect(service.status, ConnectionStatus.online);
    expect(notified, 2);
  });

  test('an update that changes nothing does not notify', () async {
    await service.start();
    var notified = 0;
    service.addListener(() => notified++);
    changes.add([ConnectivityResult.mobile]); // still online
    expect(notified, 0);
  });

  test('a reconnect callback fires after coming back from offline, not on first start', () async {
    await service.start();
    var reconnects = 0;
    service.onReconnect(() async => reconnects++);

    changes.add([ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    expect(reconnects, 0, reason: 'going offline is not a reconnect');

    changes.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(reconnects, 1);
  });

  test('a failing reconnect callback does not stop the next one', () async {
    await service.start();
    var second = 0;
    service.onReconnect(() async => throw StateError('boom'));
    service.onReconnect(() async => second++);

    changes.add([ConnectivityResult.none]);
    changes.add([ConnectivityResult.wifi]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(second, 1);
  });

  test('if the platform plugin fails, the app assumes online instead of hiding data', () async {
    final broken = ConnectivityService.testing(
      check: () async => throw StateError('no plugin'),
      changes: () => const Stream<List<ConnectivityResult>>.empty(),
    );
    addTearDown(broken.dispose);
    await broken.start();
    expect(broken.status, ConnectionStatus.online);
  });
}
