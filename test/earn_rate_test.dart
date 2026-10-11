import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/repositories/loyalty_repository.dart';

void main() {
  test('no earn rate set by the owner is "Not set", never a made-up 50', () {
    expect(EarnRate.fromRpc(null).pesosPerPoint, isNull);
    expect(EarnRate.fromRpc(null).isSet, isFalse);
  });

  test('the owner\'s rate is used as it is', () {
    expect(EarnRate.fromRpc(25).pesosPerPoint, 25);
    expect(EarnRate.fromRpc(12.5).pesosPerPoint, 12.5);
    expect(EarnRate.fromRpc('40').pesosPerPoint, 40);
  });

  test('an invalid rate is treated as not set', () {
    expect(EarnRate.fromRpc(0).isSet, isFalse);
    expect(EarnRate.fromRpc(-3).isSet, isFalse);
    expect(EarnRate.fromRpc('abc').isSet, isFalse);
  });
}
