import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/theme/app_colors.dart';

/// WCAG 2.1 contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  const surfaces = {
    'white': Colors.white,
    'canvas': AppColors.canvas,
    'surfaceContainerLow': AppColors.surfaceContainerLow,
    'warningBg': AppColors.warningBg,
    'successBg': AppColors.successBg,
    'errorBg': AppColors.errorBg,
  };
  const textColours = {
    'textPrimary': AppColors.textPrimary,
    'textMuted': AppColors.textMuted,
    'textSecondary': AppColors.textSecondary,
    'success': AppColors.success,
    'warning': AppColors.warning,
    'error': AppColors.error,
    'darkBrown': AppColors.darkBrown,
  };

  for (final t in textColours.entries) {
    for (final s in surfaces.entries) {
      test('${t.key} text on ${s.key} meets WCAG AA (4.5:1)', () {
        expect(contrast(t.value, s.value), greaterThanOrEqualTo(4.5));
      });
    }
  }

  test('white text on the primary button colour meets WCAG AA', () {
    expect(contrast(Colors.white, AppColors.primary), greaterThanOrEqualTo(4.5));
  });
}
