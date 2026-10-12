import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/features/staff/pos_sale_attempt.dart';

/// Review fix 3: the POS idempotency key follows the request.
void main() {
  late int counter;
  late PosSaleAttempt attempt;

  String fp({Map<String, int>? cart, String method = 'cash', String? customer, String? ref}) =>
      PosSaleAttempt.fingerprintOf(
        branchId: 'branch-1',
        cart: cart ?? const {'v1': 2},
        method: method,
        customerUid: customer,
        reference: ref,
      );

  setUp(() {
    counter = 0;
    attempt = PosSaleAttempt(newKey: () => 'key-${++counter}');
  });

  test('the same request keeps its key (safe retry)', () {
    expect(attempt.keyFor(fp()), 'key-1');
    attempt.markFailed(outcomeUnknown: false);
    expect(attempt.keyFor(fp()), 'key-1');
  });

  test('a changed request after a refused attempt gets a new key', () {
    expect(attempt.keyFor(fp()), 'key-1');
    attempt.markFailed(outcomeUnknown: false);
    expect(attempt.keyFor(fp(cart: const {'v1': 5})), 'key-2', reason: 'items changed');
    attempt.markFailed(outcomeUnknown: false);
    expect(attempt.keyFor(fp(cart: const {'v1': 5}, customer: 'cust-1')), 'key-3', reason: 'customer attached');
    attempt.markFailed(outcomeUnknown: false);
    expect(attempt.keyFor(fp(cart: const {'v1': 5}, customer: 'cust-1', method: 'gcash', ref: '1234')), 'key-4',
        reason: 'payment method changed');
  });

  test('after an unknown outcome the key is kept, so the server can refuse a changed copy', () {
    expect(attempt.keyFor(fp()), 'key-1');
    attempt.markFailed(outcomeUnknown: true);
    expect(attempt.keyFor(fp(customer: 'cust-1')), 'key-1');
    attempt.markFailed(outcomeUnknown: false);
    expect(attempt.keyFor(fp(cart: const {'v1': 9})), 'key-1', reason: 'an unknown outcome is never forgotten');
    expect(attempt.currentKey, 'key-1');
  });

  test('fingerprint ignores line order and matches walk-in spellings', () {
    expect(fp(cart: const {'a': 1, 'b': 2}), fp(cart: const {'b': 2, 'a': 1}));
    expect(fp(customer: null), fp(customer: ''));
    expect(fp(cart: const {'a': 1}), isNot(fp(cart: const {'a': 2})));
  });
}
