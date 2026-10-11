import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/request_key.dart';

void main() {
  test('newRequestKey is within the server length limit and unique', () {
    final keys = {for (var i = 0; i < 200; i++) newRequestKey()};
    expect(keys.length, 200);
    for (final k in keys) {
      expect(k.startsWith('rk-'), isTrue);
      expect(k.length, inInclusiveRange(8, 100)); // staff_request_keys check constraint
      expect(RegExp(r'^rk-[0-9a-f]{32}$').hasMatch(k), isTrue);
    }
  });

  group('RequestKeyHolder', () {
    late int n;
    late RequestKeyHolder holder;
    setUp(() {
      n = 0;
      holder = RequestKeyHolder(generate: () => 'key-${++n}');
    });

    test('the same inputs reuse the same key (a retry after a timeout)', () {
      final first = holder.keyFor('[1,2,3]');
      expect(holder.keyFor('[1,2,3]'), first);
      expect(holder.keyFor('[1,2,3]'), first);
      expect(n, 1);
    });

    test('changed inputs get a new key (the server refuses a key reused for a different request)', () {
      final first = holder.keyFor('[1,2,3]');
      final second = holder.keyFor('[1,2,4]');
      expect(second, isNot(first));
      expect(n, 2);
    });

    test('going back to earlier inputs does not resurrect the old key', () {
      final a = holder.keyFor('A');
      holder.keyFor('B');
      expect(holder.keyFor('A'), isNot(a));
    });

    test('reset forgets the key', () {
      final first = holder.keyFor('A');
      holder.reset();
      expect(holder.keyFor('A'), isNot(first));
    });
  });
}
