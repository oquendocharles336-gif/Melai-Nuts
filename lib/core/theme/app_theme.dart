import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Material 3 ThemeData for the whole app.
///
/// Bright and warm: cream canvas, white cards, an orange app bar and main
/// buttons, and bold rounded headings.
class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      // Accessibility: every control gets at least a 48 x 48 tap target.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        secondary: AppColors.secondaryBrown,
        surface: AppColors.canvas,
        onSurface: AppColors.textPrimary,
        error: AppColors.error,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: AppColors.canvas,
      fontFamily: GoogleFonts.plusJakartaSans().fontFamily,
    );

    final buttonText = GoogleFonts.plusJakartaSans(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.1,
    );
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    OutlineInputBorder inputBorder([BorderSide side = BorderSide.none]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: side);

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.appBar,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        iconTheme: const IconThemeData(color: AppColors.gold),
        actionsIconTheme: const IconThemeData(color: AppColors.gold),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: GoogleFonts.plusJakartaSans(color: AppColors.textSecondary, fontSize: 14),
        border: inputBorder(const BorderSide(color: AppColors.border)),
        enabledBorder: inputBorder(const BorderSide(color: AppColors.border)),
        disabledBorder: inputBorder(const BorderSide(color: AppColors.border)),
        focusedBorder: inputBorder(const BorderSide(color: AppColors.primary, width: 1.4)),
        errorBorder: inputBorder(const BorderSide(color: AppColors.error, width: 1.2)),
        focusedErrorBorder: inputBorder(const BorderSide(color: AppColors.error, width: 1.4)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 54),
          elevation: 0,
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 54),
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: const Size(64, 54),
          side: const BorderSide(color: AppColors.outlineButton, width: 1.2),
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // 48 x 48 minimum tap target (Material / WCAG 2.5.8).
          minimumSize: const Size(48, 48),
          foregroundColor: AppColors.primary,
          textStyle: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.inputFill,
        selectedColor: AppColors.primary.withValues(alpha: 0.12),
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: GoogleFonts.plusJakartaSans(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.ink : AppColors.textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? const IconThemeData(color: AppColors.primaryDark, size: 24)
              : const IconThemeData(color: AppColors.textSecondary, size: 24);
        }),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 32,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.darkBrown,
        contentTextStyle: GoogleFonts.plusJakartaSans(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
