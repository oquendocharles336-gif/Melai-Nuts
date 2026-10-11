import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Typography scale matching the prototype's "Plus Jakarta Sans" system.
class AppTextStyles {
  AppTextStyles._();

  static TextStyle _base({
    required double size,
    required FontWeight weight,
    double? height,
    double? letterSpacing,
    Color color = AppColors.textPrimary,
  }) {
    try {
      return GoogleFonts.plusJakartaSans(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
        color: color,
      );
    } catch (_) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
        color: color,
        fontFamily: 'Sans-Serif',
      );
    }
  }

  static TextStyle headlineLg = _base(size: 26, weight: FontWeight.w700);
  static TextStyle headlineMd = _base(size: 22, weight: FontWeight.w700);
  static TextStyle headlineSm = _base(size: 18, weight: FontWeight.w600);
  static TextStyle titleMd = _base(size: 16, weight: FontWeight.w600);
  static TextStyle bodyLg = _base(size: 16, weight: FontWeight.w400);
  static TextStyle bodyMd = _base(
    size: 14,
    weight: FontWeight.w400,
    color: AppColors.textMuted,
  );
  static TextStyle bodySm = _base(
    size: 12,
    weight: FontWeight.w400,
    color: AppColors.textSecondary,
  );
  static TextStyle labelLg = _base(size: 14, weight: FontWeight.w600);
  static TextStyle labelMd = _base(
    size: 12,
    weight: FontWeight.w600,
    letterSpacing: 0.3,
    color: AppColors.textSecondary,
  );
  static TextStyle labelSm = _base(
    size: 11,
    weight: FontWeight.w700,
    letterSpacing: 0.5,
    color: AppColors.textSecondary,
  );
}
