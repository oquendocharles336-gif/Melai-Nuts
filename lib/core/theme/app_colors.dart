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
  static const Color canvas = Color(0xFFFFF9F0); // warm cream page background
  static const Color surface = Color(0xFFFFF9F0); // header strip
  static const Color surfaceContainer = Color(0xFFFFFFFF); // cards, panels
  static const Color surfaceContainerHigh = Color(0xFFFFEFD6);
  static const Color surfaceContainerLow = Color(0xFFFFFCF6);
  static const Color border = Color(0xFFF3E1C4); // hairlines, card borders
  static const Color inputFill = Color(0xFFFFF6E8); // low-chrome filled text fields
  static const Color outlineButton = Color(0xFFE5B574); // outlined secondary buttons
  static const Color outlineVariant = Color(0xFFD7C2B7);

  // ---- Brand / structural core -----------------------------------------
  static const Color primary = Color(0xFFBF4409); // roasted orange: buttons, accents and accent text
  static const Color primaryDark = Color(0xFF9A3412); // pressed/hover
  static const Color primaryContainer = Color(0xFFFFE6C2);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1F120B); // warm near-black: headings and body text
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
  static const Color roleOwner = Color(0xFFBF4409);
  static const Color roleStaff = Color(0xFF0F766E);
  static const Color roleDelivery = Color(0xFF387B44);
  static const Color roleCustomer = Color(0xFF91571C);

  // ---- Gradients and accents (hero banners, loyalty card) ----------------
  // Kept here so no screen hard-codes a colour (docs/DESIGN_GUIDE.md).
  static const Color heroGradientStart = Color(0xFFC2410C);
  static const Color heroGradientEnd = Color(0xFFC8480A);
  static const Color primaryDeep = Color(0xFF9A3412);
  static const Color loyaltyGradientEnd = Color(0xFFC8480A);
  static const Color gold = Color(0xFFFFF9EC); // warm cream: text and icons on the orange hero
  static const Color honey = Color(0xFFFFC94D); // rewards card, promo badges, main button on the hero (dark text on it)
  static const Color honeyDeep = Color(0xFFF5A623);
  static const Color appBar = heroGradientStart;
  static const Color sunStart = Color(0xFFFFF6E3); // sunny full-screen background (splash, welcome, sign in)
  static const Color sunEnd = Color(0xFFFFD98F);
  static const Color ivory = Color(0xFFFFFCF6); // sheets and cards on dark backgrounds
  static const Color productCardGradientStart = Color(0xFFBE7B47);
}
