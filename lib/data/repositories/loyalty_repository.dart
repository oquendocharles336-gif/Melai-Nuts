import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../models/loyalty.dart';

/// Reads the customer's real points balance/history and redeems rewards.
///
/// Points are never written directly from the client: they're earned by a
/// database trigger when an order is placed, and spent by the
/// `redeem_reward` Postgres function (atomic check-and-deduct — see
/// supabase/schema.sql), so a balance can't be inflated or double-spent.
class LoyaltyRepository {
  LoyaltyRepository._();
  static final LoyaltyRepository instance = LoyaltyRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<int> fetchBalance(String firebaseUid) async {
    final row = await _client
        .from('loyalty_accounts')
        .select('points_balance')
        .eq('firebase_uid', firebaseUid)
        .maybeSingle();
    return (row?['points_balance'] as int?) ?? 0;
  }

  /// Pesos spent per 1 point earned, as set by the owner in the admin portal
  /// (`loyalty_cart_settings.earn_pesos_per_point`, read through the public
  /// `get_loyalty_earn_rate` function). The database applies the same value
  /// when it computes an order's points, so the text shown always matches.
  /// [EarnRate.pesosPerPoint] is null when the owner has not set a rate
  /// ("Not set": orders earn no points) — no value is invented here.
  Future<EarnRate> fetchEarnPesosPerPoint() async {
    final result = await _client.rpc('get_loyalty_earn_rate');
    return EarnRate.fromRpc(result);
  }

  Future<List<LoyaltyPointTransaction>> fetchTransactions(String firebaseUid) async {
    final raw = await _client
        .from('loyalty_transactions')
        .select()
        .eq('firebase_uid', firebaseUid)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(raw).map(LoyaltyPointTransaction.fromRow).toList();
  }

  Future<List<RewardItem>> fetchRewards() async {
    final raw = await _client.from('rewards').select().eq('is_active', true).order('points_required');
    return List<Map<String, dynamic>>.from(raw).map(RewardItem.fromRow).toList();
  }

  /// Redeems [rewardId] for the signed-in customer. Returns the new points
  /// balance. Throws a [PostgrestException] (surfaced as a plain message by
  /// the caller) if the reward is unavailable or the balance is too low.
  Future<int> redeemReward(String rewardId) async {
    final result = await _client.rpc('redeem_reward', params: {'p_reward_id': rewardId});
    return result as int;
  }
}

/// The owner's loyalty earn rate (pesos spent per point), or null = Not set.
class EarnRate {
  final double? pesosPerPoint;

  const EarnRate(this.pesosPerPoint);

  /// `get_loyalty_earn_rate()` answers a number, or NULL when not set. A value
  /// below 1 is not a valid rate (the database refuses to store one).
  factory EarnRate.fromRpc(Object? result) {
    final v = result is num ? result.toDouble() : (result is String ? double.tryParse(result) : null);
    return EarnRate((v == null || v < 1) ? null : v);
  }

  bool get isSet => pesosPerPoint != null;
}
