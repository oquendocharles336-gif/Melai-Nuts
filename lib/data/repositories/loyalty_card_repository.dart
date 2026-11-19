import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/loyalty_card.dart';

/// The customer's card self-service (migration 20261119050000): readers,
/// "Link my card" sessions, block / remove, and the optional loyalty PIN.
///
/// Everything is a database function; the app never writes a card, a session
/// or points itself. Linking happens on the server when the card is tapped on
/// the ESP32 reader (Edge Function rfid-device-tap).
class LoyaltyCardRepository {
  LoyaltyCardRepository._();
  static final LoyaltyCardRepository instance = LoyaltyCardRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) =>
      AppErrors.guard<dynamic>(() async => await _client.rpc(fn, params: params), timeout: AppErrors.rpcTimeout);

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  Future<MyLoyaltyCard> fetchMyCard() async => MyLoyaltyCard.fromJson(await _rpc('get_my_loyalty_card'));

  Future<List<CardReader>> fetchReaders() async {
    final raw = await _rpc('customer_list_card_readers');
    final list = raw is List ? raw : const [];
    return [for (final r in list) if (r is Map) CardReader.fromJson(Map<String, dynamic>.from(r))];
  }

  Future<CardPairing> startPairing(String readerId) async =>
      CardPairing.fromJson(_map(await _rpc('customer_start_card_pairing', {'p_device_id': readerId})));

  Future<CardPairing> fetchPairing(String sessionId) async =>
      CardPairing.fromJson(_map(await _rpc('customer_get_card_pairing', {'p_session_id': sessionId})));

  Future<CardPairing> cancelPairing(String sessionId) async =>
      CardPairing.fromJson(_map(await _rpc('customer_cancel_card_pairing', {'p_session_id': sessionId})));

  Future<MyLoyaltyCard> blockMyCard(String? reason) async =>
      MyLoyaltyCard.fromJson(await _rpc('customer_block_my_card', {'p_reason': reason}));

  Future<MyLoyaltyCard> removeMyCard() async => MyLoyaltyCard.fromJson(await _rpc('customer_remove_my_card'));

  Future<LoyaltyPinStatus> fetchPinStatus() async => LoyaltyPinStatus.fromJson(await _rpc('get_my_loyalty_pin_status'));

  /// Returns null on success, otherwise the reason to show (wrong / locked current PIN).
  Future<String?> setPin(String newPin, {String? currentPin}) async =>
      _pinAnswer(_map(await _rpc('customer_set_loyalty_pin', {'p_new_pin': newPin, 'p_current_pin': currentPin})));

  Future<String?> clearPin(String currentPin) async =>
      _pinAnswer(_map(await _rpc('customer_clear_loyalty_pin', {'p_current_pin': currentPin})));

  static String? _pinAnswer(Map<String, dynamic> j) {
    if (j['ok'] == true) return null;
    if (j['reason'] == 'locked') return 'Too many wrong PINs. Try again in 15 minutes.';
    final left = (j['attempts_left'] as num?)?.toInt();
    return left == null ? 'The current PIN is not correct.' : 'The current PIN is not correct ($left tries left).';
  }
}
