import 'package:flutter/material.dart';
import '../repositories/icon_registry.dart';

enum LoyaltyTransactionType { earn, redeem }

/// Passed as route arguments to [RedemptionSuccessScreen] once a redemption
/// has actually been recorded server-side — [pointsAfter] is the real new
/// balance returned by the `redeem_reward` Supabase function, never a guess.
class RedemptionResult {
  final RewardItem reward;
  final int pointsAfter;

  const RedemptionResult({required this.reward, required this.pointsAfter});
}

class LoyaltyPointTransaction {
  final String id;
  final DateTime date;
  final int points;
  final LoyaltyTransactionType type;
  final String description;

  /// Why the ledger row exists (`loyalty_transactions.source`): order_earn,
  /// order_redeem, order_return, order_clawback (points taken back because the
  /// order was refunded, in proportion to the amount refunded), admin_adjust.
  final String? source;
  final String? orderId;

  LoyaltyPointTransaction({
    required this.id,
    required this.date,
    required this.points,
    required this.type,
    required this.description,
    this.source,
    this.orderId,
  });

  /// Points reversed because an order was (partly) refunded — not points the
  /// customer spent.
  bool get isRefundReversal => source == 'order_clawback';

  factory LoyaltyPointTransaction.fromRow(Map<String, dynamic> row) {
    return LoyaltyPointTransaction(
      id: row['id'] as String,
      date: DateTime.parse(row['created_at'] as String).toLocal(),
      points: (row['points'] as int).abs(),
      type: LoyaltyTransactionType.values.byName(row['type'] as String),
      description: row['description'] as String,
      source: row['source'] as String?,
      orderId: row['order_id'] as String?,
    );
  }
}

/// A redeemable loyalty reward.
///
/// [icon] + [color] render an on-brand placeholder tile (matching
/// [ProductThumbnail] elsewhere in the app) instead of a network photo, so
/// rewards stay consistent with the rest of the frontend-only, offline app.
class RewardItem {
  final String id;
  final String title;
  final String description;
  final int pointsRequired;
  final String badgeLabel; // e.g. "Instant Voucher", "Most Popular"
  final IconData icon;
  final Color color;

  RewardItem({
    required this.id,
    required this.title,
    required this.description,
    required this.pointsRequired,
    required this.badgeLabel,
    required this.icon,
    required this.color,
  });

  factory RewardItem.fromRow(Map<String, dynamic> row) {
    return RewardItem(
      id: row['id'] as String,
      title: row['title'] as String,
      description: (row['description'] as String?) ?? '',
      pointsRequired: row['points_required'] as int,
      badgeLabel: (row['badge_label'] as String?) ?? '',
      icon: IconRegistry.icon(row['icon_name'] as String?, fallback: Icons.redeem_rounded),
      color: IconRegistry.color(row['color_hex'] as String?),
    );
  }
}
