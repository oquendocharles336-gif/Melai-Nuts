import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/nfc_card_reader.dart';
import 'package:melai_nuts/data/models/loyalty_card.dart';
import 'package:melai_nuts/data/models/staff_models.dart';
import 'package:melai_nuts/features/staff/pos_sale_attempt.dart';

/// RFID self-link, card status and POS points (migration 20261119050000).
void main() {
  group('MyLoyaltyCard', () {
    test('no card at all is not active', () {
      expect(MyLoyaltyCard.fromJson(null).isActive, isFalse);
      expect(MyLoyaltyCard.fromJson(null).status, LoyaltyCardStatus.none);
    });

    test('active only with status active AND a label', () {
      expect(MyLoyaltyCard.fromJson({'status': 'active', 'label': 'GK-1A2B-3C4D'}).isActive, isTrue);
      expect(MyLoyaltyCard.fromJson({'status': 'active', 'label': ''}).isActive, isFalse);
      expect(MyLoyaltyCard.fromJson({'status': 'blocked', 'label': 'GK-1A2B-3C4D'}).isActive, isFalse);
      expect(MyLoyaltyCard.fromJson({'status': 'replaced', 'label': 'GK-1A2B-3C4D'}).isActive, isFalse);
    });

    test('blocked and active cards can be removed; a retired one cannot', () {
      expect(MyLoyaltyCard.fromJson({'status': 'blocked', 'label': 'GK-1'}).canBeRemoved, isTrue);
      expect(MyLoyaltyCard.fromJson({'status': 'replaced', 'label': 'GK-1'}).canBeRemoved, isFalse);
    });
  });

  group('CardPairing', () {
    test('uses the server countdown, and realtime rows keep it', () {
      final p = CardPairing.fromJson({'id': 's1', 'status': 'waiting', 'seconds_left': 42, 'device_name': 'Counter 1'});
      expect(p.isWaiting, isTrue);
      expect(p.secondsLeft, inInclusiveRange(40, 42));
      final linked = p.mergeRow({'status': 'linked', 'card_label': 'GK-1', 'points_balance': 120});
      expect(linked.isSuccess, isTrue);
      expect(linked.pointsBalance, 120);
      expect(linked.deviceName, 'Counter 1');
      expect(linked.secondsLeft, 0);
    });

    test('a refused card is not a success', () {
      final p = CardPairing.fromJson({'id': 's1', 'status': 'failed', 'result_code': 'card_taken', 'seconds_left': 0});
      expect(p.isSuccess, isFalse);
      expect(p.isWaiting, isFalse);
    });
  });

  group('POS', () {
    test('redeeming points is a different request (new idempotency key after a refusal)', () {
      String fp(bool redeem) => PosSaleAttempt.fingerprintOf(
            branchId: 'b', cart: const {'v1': 1}, method: 'cash', customerUid: 'c1', redeemPoints: redeem);
      expect(fp(true), isNot(fp(false)));
      // Unchanged for sales without points (existing keys keep matching).
      expect(fp(false), PosSaleAttempt.fingerprintOf(branchId: 'b', cart: const {'v1': 1}, method: 'cash', customerUid: 'c1'));
    });

    test('quote and sale result read the database totals', () {
      final q = PosQuote.fromJson({
        'subtotal': 200, 'points_used': 100, 'loyalty_discount': 100, 'total': 100, 'points_to_earn': 2,
        'points_balance': 120, 'redeem_configured': true, 'max_points_redeemable': 100, 'max_discount': 100,
        'pin_required': true,
      });
      expect(q.total, 100);
      expect(q.canRedeem, isTrue);
      expect(q.pinRequired, isTrue);
      final r = PosSaleResult.fromJson({
        'order_id': 'ORD-1', 'subtotal': 200, 'loyalty_discount': 100, 'points_redeemed': 100, 'total': 100,
        'points_earned': 2, 'change': 0, 'payment_id': 'p', 'already_recorded': false,
      });
      expect(r.pointsRedeemed, 100);
      expect(r.subtotal, 200);
    });

    test('a blocked card never reveals its owner', () {
      final l = CardLookup.fromJson({'status': 'blocked', 'card': {'label': 'GK-1'}});
      expect(l.isActive, isFalse);
      expect(l.customer, isNull);
      expect(l.problem, contains('blocked'));
      final ok = CardLookup.fromJson({
        'status': 'active',
        'card': {'label': 'GK-1'},
        'customer': {'firebase_uid': 'c1', 'full_name': 'Ana', 'points_balance': 5},
      });
      expect(ok.isActive, isTrue);
      expect(ok.customer!.uid, 'c1');
    });

    test('NFC UID bytes become the upper-case hex the server expects', () {
      expect(NfcCardReader.toHex(Uint8List.fromList([0x04, 0xa1, 0xb2, 0x0c])), '04A1B20C');
    });
  });
}
