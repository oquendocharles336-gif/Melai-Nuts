import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/checkout_attempt_store.dart';
import 'package:melai_nuts/data/models/order.dart';

/// Regression tests for the checkout idempotency key.
///
/// The server answers a repeated key with the FIRST order stored for it and
/// never compares the request. So the store must reuse a key only for the
/// identical request, and must ask the server about an unconfirmed attempt
/// before replacing its key. See finding 1 of the customer-flow audit.
class _MemoryStorage implements CheckoutAttemptStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> remove() async => value = null;
}

Order _order(String id) => Order(
      id: id,
      date: DateTime(2026, 10, 7),
      status: OrderStatus.pending,
      branch: 'Test Branch',
      isDelivery: false,
      items: const [],
      deliveryFee: 0,
      paymentMethod: 'Cash on Counter Pickup',
      pointsEarned: 0,
    );

const _pickupCash = '[false,null,"Cash on Counter Pickup",""]';
const _deliveryGcash = '[true,"addr-1","GCash E-Wallet",""]';

void main() {
  late _MemoryStorage storage;
  late DateTime clock;
  late int keyCounter;
  late Map<String, Order> serverOrders; // idempotency key -> order the server stored
  late List<String> lookups;
  late bool offline;
  late CheckoutAttemptStore store;

  setUp(() {
    storage = _MemoryStorage();
    clock = DateTime(2026, 10, 7, 12);
    keyCounter = 0;
    serverOrders = {};
    lookups = [];
    offline = false;
    store = CheckoutAttemptStore.withDependencies(
      storage: storage,
      now: () => clock,
      newKey: () => 'key-${++keyCounter}',
      lookup: (uid, key) async {
        lookups.add(key);
        if (offline) throw Exception('offline');
        return serverOrders[key];
      },
    );
  });

  Future<CheckoutAttempt> begin(String fingerprint, {String uid = 'u1', String cart = 'cart-1'}) =>
      store.begin(uid: uid, cartId: cart, fingerprint: fingerprint);

  test('retrying the identical request reuses the same key', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    final retry = await begin(_pickupCash);
    expect(retry.key, first.key);
    expect(lookups, isEmpty, reason: 'no server round trip needed for an identical retry');
  });

  test('changing options BEFORE anything was sent mints a new key without asking the server', () async {
    final first = await begin(_pickupCash); // never markSubmitted
    final second = await begin(_deliveryGcash);
    expect(second.key, isNot(first.key));
    expect(second.fingerprint, _deliveryGcash);
    expect(lookups, isEmpty);
  });

  test('REGRESSION: changing options after an unknown outcome that DID commit returns the earlier order', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    serverOrders[first.key] = _order('order-from-first-attempt');

    // The customer switches to delivery + GCash and taps Place Order again.
    // Before the fix this reused first.key and the server silently returned the
    // original pickup/cash order.
    await expectLater(
      begin(_deliveryGcash),
      throwsA(isA<CheckoutAlreadyPlacedException>()
          .having((e) => e.order.id, 'order id', 'order-from-first-attempt')),
    );
    expect(lookups, [first.key]);
    expect(storage.value, isNull, reason: 'the settled attempt is forgotten');
  });

  test('changing options after an unknown outcome that did NOT commit mints a new key', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    // serverOrders is empty: the server never accepted it.
    final second = await begin(_deliveryGcash);
    expect(second.key, isNot(first.key));
    expect(lookups, [first.key]);
  });

  test('changing options while offline after an unknown outcome refuses and keeps the old attempt', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    offline = true;
    await expectLater(begin(_deliveryGcash), throwsException);
    // Minting a new key here could place a second order, so the old attempt stays.
    final saved = CheckoutAttempt.fromJson(jsonDecode(storage.value!) as Map<String, dynamic>);
    expect(saved.key, first.key);
    expect(saved.submitted, isTrue);
  });

  test('an attempt saved by an older app version (no fingerprint) is not reused for a new request', () async {
    storage.value = jsonEncode({
      'key': 'legacy-key',
      'uid': 'u1',
      'cartId': 'cart-1',
      'createdAt': clock.toIso8601String(),
      'submitted': false,
    });
    final attempt = await begin(_pickupCash);
    expect(attempt.key, isNot('legacy-key'));
  });

  test('an unconfirmed legacy attempt is still checked against the server before being replaced', () async {
    storage.value = jsonEncode({
      'key': 'legacy-key',
      'uid': 'u1',
      'cartId': 'cart-1',
      'createdAt': clock.toIso8601String(),
      'submitted': true,
    });
    serverOrders['legacy-key'] = _order('legacy-order');
    await expectLater(begin(_pickupCash), throwsA(isA<CheckoutAlreadyPlacedException>()));
  });

  test('a different cart or customer never inherits a key', () async {
    final first = await begin(_pickupCash);
    expect((await begin(_pickupCash, cart: 'cart-2')).key, isNot(first.key));
    final other = await begin(_pickupCash, uid: 'u2', cart: 'cart-2');
    expect(other.uid, 'u2');
  });

  test('an attempt older than 24h is replaced', () async {
    final first = await begin(_pickupCash);
    clock = clock.add(const Duration(hours: 25));
    expect((await begin(_pickupCash)).key, isNot(first.key));
  });

  test('the attempt survives a restart and still dedupes the identical request', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    final restarted = CheckoutAttemptStore.withDependencies(
      storage: storage,
      now: () => clock,
      newKey: () => 'key-after-restart',
      lookup: (uid, key) async => serverOrders[key],
    );
    final retry = await restarted.begin(uid: 'u1', cartId: 'cart-1', fingerprint: _pickupCash);
    expect(retry.key, first.key);
    expect(retry.submitted, isTrue);
  });

  test('resolveUnconfirmed recovers an accepted order and clears the attempt', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    serverOrders[first.key] = _order('recovered');
    await store.resolveUnconfirmed('u1');
    expect(store.recoveredOrder?.id, 'recovered');
    expect(storage.value, isNull);
  });

  test('resolveUnconfirmed keeps an attempt the server never saw', () async {
    final first = await begin(_pickupCash);
    await store.markSubmitted(first);
    await store.resolveUnconfirmed('u1');
    expect(store.recoveredOrder, isNull);
    expect(storage.value, isNotNull);
  });
}
