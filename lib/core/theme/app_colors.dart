import 'package:flutter/material.dart';

/// Central color palette for Melai Nuts Retailing.
///
/// Sourced from the "Warm Harvest Modern" design system used across the
/// Melai Nuts prototype (see stitch prototype export, warm_harvest_modern
/// DESIGN.md). Keep this file as the single source of truth for color so
/// every screen/feature stays visually consistent.
class AppColors {
  AppColors._();

  // ---- Canvas / surfaces ----------------------------------------------
  static const Color canvas = Color(0xFFFDFBF7); // root viewport background
  static const Color surface = Color(0xFFFFF8F4); // app-bar / header strip
  static const Color surfaceContainer = Color(0xFFFAF6EE); // cards, panels
  static const Color surfaceContainerHigh = Color(0xFFF1E6DC);
  static const Color surfaceContainerLow = Color(0xFFFDF2E8);
  static const Color border = Color(0xFFE8E2D9); // hairlines, card borders
  static const Color outlineVariant = Color(0xFFD7C2B7);

  // ---- Brand / structural core -----------------------------------------
  static const Color primary = Color(0xFFA06235); // warm peanut brown
  static const Color primaryDark = Color(0xFF875129); // pressed/hover
  static const Color primaryContainer = Color(0xFFFFDCC6);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color darkBrown = Color(0xFF4A2C18); // headings / high-emphasis
  static const Color secondaryBrown = Color(0xFF7B563F);

  // ---- Status / accents --------------------------------------------------
  static const Color success = Color(0xFF387B44); // fresh leaf green
  static const Color successBg = Color(0xFFEAF3EC);
  static const Color warning = Color(0xFFD9822B); // golden honey
  static const Color warningBg = Color(0xFFFDF1E3);
  static const Color error = Color(0xFFC23E3E);
  static const Color errorBg = Color(0xFFFFDAD6);

  // ---- Neutrals / text -----------------------------------------------
  static const Color textPrimary = Color(0xFF201B15); // on-surface
  static const Color textSecondary = Color(0xFF7D756D); // metadata / labels
  static const Color textMuted = Color(0xFF52443B); // on-surface-variant

  // ---- Role accent colors (used for badges/portals) --------------------
  static const Color roleOwner = Color(0xFFA06235);
  static const Color roleStaff = Color(0xFF7B563F);
  static const Color roleDelivery = Color(0xFF387B44);
  static const Color roleCustomer = Color(0xFFD9822B);
}
