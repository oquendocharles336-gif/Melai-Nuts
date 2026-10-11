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
  static const Color success = Color(0xFF33713E); // fresh leaf green, 4.5:1+ on every light surface
  static const Color successBg = Color(0xFFEAF3EC);
  static const Color warning = Color(0xFF91571C); // honey brown (was D9822B: 2.9:1 on white, failed WCAG AA; now 4.5:1+)
  static const Color warningBg = Color(0xFFFDF1E3);
  static const Color error = Color(0xFFB43939); // 4.5:1+ also on errorBg
  static const Color errorBg = Color(0xFFFFDAD6);

  // ---- Neutrals / text -----------------------------------------------
  static const Color textPrimary = Color(0xFF201B15); // on-surface
  static const Color textSecondary = Color(0xFF6B645D); // metadata / labels (WCAG AA 4.5:1 on every light surface)
  static const Color textMuted = Color(0xFF52443B); // on-surface-variant

  // ---- Role accent colors (used for badges/portals) --------------------
  static const Color roleOwner = Color(0xFFA06235);
  static const Color roleStaff = Color(0xFF7B563F);
  static const Color roleDelivery = Color(0xFF387B44);
  static const Color roleCustomer = Color(0xFF91571C);

  // ---- Gradients and accents (hero banners, loyalty card) ----------------
  // Kept here so no screen hard-codes a colour (docs/DESIGN_GUIDE.md).
  static const Color heroGradientStart = Color(0xFF6B3F1E);
  static const Color heroGradientEnd = Color(0xFFC48A55);
  static const Color primaryDeep = Color(0xFF5E3519);
  static const Color loyaltyGradientEnd = Color(0xFF8A5530);
  static const Color gold = Color(0xFFFFD27A);
  static const Color productCardGradientStart = Color(0xFFBE7B47);
}
