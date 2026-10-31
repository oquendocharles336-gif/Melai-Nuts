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
  static const Color canvas = Color(0xFFF3E9DA); // champagne page background
  static const Color surface = Color(0xFFF3E9DA); // app-bar / header strip
  static const Color surfaceContainer = Color(0xFFFFFFFF); // cards, panels
  static const Color surfaceContainerHigh = Color(0xFFE9DAC2);
  static const Color surfaceContainerLow = Color(0xFFF9F1E3);
  static const Color border = Color(0xFFE2CFA6); // hairlines, card borders
  static const Color inputFill = Color(0xFFF6EEDF); // low-chrome filled text fields
  static const Color outlineButton = Color(0xFFC9AC72); // outlined secondary buttons
  static const Color outlineVariant = Color(0xFFD7C2B7);

  // ---- Brand / structural core -----------------------------------------
  static const Color primary = Color(0xFF8A5A14); // antique bronze: accents and accent text
  static const Color primaryDark = Color(0xFF6B430C); // pressed/hover
  static const Color primaryContainer = Color(0xFFF6E3B8);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1F120B); // deep espresso: headings and body text
  static const Color darkBrown = Color(0xFF2A1810); // headings / high-emphasis
  static const Color secondaryBrown = Color(0xFF7B563F);

  // ---- Status / accents --------------------------------------------------
  static const Color success = Color(0xFF33713E); // fresh leaf green, 4.5:1+ on every light surface
  static const Color successBg = Color(0xFFEAF3EC);
  static const Color warning = Color(0xFF91571C); // honey brown (was D9822B: 2.9:1 on white, failed WCAG AA; now 4.5:1+)
  static const Color warningBg = Color(0xFFFDF1E3);
  static const Color error = Color(0xFFB43939); // 4.5:1+ also on errorBg
  static const Color errorBg = Color(0xFFFFDAD6);

  // ---- Neutrals / text -----------------------------------------------
  static const Color textPrimary = ink; // on-surface
  static const Color textSecondary = Color(0xFF6E5E50); // metadata / labels (WCAG AA 4.5:1 on every light surface)
  static const Color textMuted = Color(0xFF52443B); // on-surface-variant

  // ---- Role accent colors (used for badges/portals) --------------------
  static const Color roleOwner = Color(0xFF8A5A14);
  static const Color roleStaff = Color(0xFF7B563F);
  static const Color roleDelivery = Color(0xFF387B44);
  static const Color roleCustomer = Color(0xFF91571C);

  // ---- Gradients and accents (hero banners, loyalty card) ----------------
  // Kept here so no screen hard-codes a colour (docs/DESIGN_GUIDE.md).
  static const Color heroGradientStart = Color(0xFF0D0907);
  static const Color heroGradientEnd = Color(0xFF21140C);
  static const Color primaryDeep = Color(0xFF3A2110);
  static const Color loyaltyGradientEnd = Color(0xFF4A2A14);
  static const Color gold = Color(0xFFF2CF85);
  static const Color honey = Color(0xFFE8BE6A); // rewards card, promo badges (espresso text on it)
  static const Color honeyDeep = Color(0xFFC9983F);
  static const Color noir = Color(0xFF0D0907); // headers and the bottom bar
  static const Color ivory = Color(0xFFFFFCF6); // sheets and cards on dark backgrounds
  static const Color productCardGradientStart = Color(0xFFBE7B47);
}
