import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';
import '../utils/app_error.dart';

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
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'app_text_styles:24');
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

  /// Serif for headings (lining figures, so numbers sit level with the text).
  static TextStyle _serif({required double size, double? height}) {
    try {
      return GoogleFonts.playfairDisplay(
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: height,
        color: AppColors.textPrimary,
        fontFeatures: const [FontFeature.liningFigures()],
      );
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'app_text_styles:serif');
      return TextStyle(fontSize: size, fontWeight: FontWeight.w700, height: height, color: AppColors.textPrimary, fontFamily: 'serif');
    }
  }

  /// The largest screen headings (Welcome, Sign In, Create Account).
  static TextStyle display = _serif(size: 32, height: 1.15);
  static TextStyle headlineLg = _serif(size: 26);
  static TextStyle headlineMd = _serif(size: 22);
  static TextStyle headlineSm = _serif(size: 19);
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
