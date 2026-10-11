import 'package:flutter/material.dart';

/// Global spacing scale (matches the prototype's 4px/8px modular base —
/// see warm_harvest_modern DESIGN.md "spacing" tokens).
///
/// Use these instead of hard-coded padding/margin numbers so every screen
/// stays visually consistent as new batches are added.
class AppSpacing {
  AppSpacing._();

  static const double xs2 = 4; // space-2xs
  static const double xs = 8; // space-xs
  static const double sm = 12; // space-sm
  static const double md = 16; // space-md (default screen gutter)
  static const double lg = 24; // space-lg
  static const double xl = 32; // space-xl
  static const double xl2 = 48; // space-2xl

  /// Standard corner radii (see DESIGN.md "Shapes").
  static const double radiusSm = 8; // inputs, chips
  static const double radiusMd = 16; // cards, panels
  static const double radiusLg = 24; // modals, drawers, hero cards
}

class AppShadows {
  AppShadows._();

  static List<BoxShadow> get sm => [
    BoxShadow(
      color: const Color(0xFF201B15).withValues(alpha: 0.05),
      blurRadius: 10,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> get md => [
    BoxShadow(
      color: const Color(0xFF201B15).withValues(alpha: 0.08),
      blurRadius: 16,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> get lg => [
    BoxShadow(
      color: const Color(0xFF201B15).withValues(alpha: 0.12),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];
}
