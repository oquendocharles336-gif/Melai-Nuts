import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/features/staff/screens/pos_flow_screens.dart';

/// Same rule as the database's `_normalize_card_uid` (loyalty_cards migration).
void main() {
  test('reader output is recognised as a card UID', () {
    expect(looksLikeCardUid('04A1B2C3'), isTrue);
    expect(looksLikeCardUid('04:a1:b2:c3'), isTrue);
    expect(looksLikeCardUid('04 11 22 33 44 55 66'), isTrue);
    expect(looksLikeCardUid('0012345678'), isTrue); // decimal keyboard readers
  });

  test('phone, e-mail and labels are not card UIDs', () {
    expect(looksLikeCardUid('juan@email.com'), isFalse);
    expect(looksLikeCardUid('GK-3F9A-71C2'), isFalse);
    expect(looksLikeCardUid('12AB'), isFalse);
    expect(looksLikeCardUid('+63 917 123 4567'), isFalse);
  });
}
