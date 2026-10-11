import 'package:flutter/material.dart';
import '../repositories/icon_registry.dart';

/// A single home-dashboard promo banner backed by the `promotions` table.
///
/// There is no fabricated fallback banner anywhere in the app: if this list
/// is empty (no active, in-date-window rows), the Home screen simply hides
/// the promo section instead of showing a made-up offer.
class Promotion {
  final String id;
  final String title;
  final String subtitle;
  final String badgeLabel;
  final IconData icon;

  const Promotion({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.badgeLabel,
    required this.icon,
  });

  factory Promotion.fromRow(Map<String, dynamic> row) {
    return Promotion(
      id: row['id'] as String,
      title: row['title'] as String,
      subtitle: (row['subtitle'] as String?) ?? '',
      badgeLabel: (row['badge_label'] as String?) ?? 'LIMITED TIME OFFER',
      icon: IconRegistry.icon(row['icon_name'] as String?, fallback: Icons.local_offer_rounded),
    );
  }
}
