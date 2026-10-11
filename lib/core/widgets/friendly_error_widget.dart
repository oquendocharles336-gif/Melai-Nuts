import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Replaces Flutter's red (debug) / grey (release) "error box" that appears
/// when a widget throws while building. In release builds the customer sees a
/// calm, translated message instead of a blank grey area; debug builds keep
/// Flutter's detailed box for the developer. The error itself is still sent
/// to the crash reporter by `FlutterError.onError` (CrashReporter.init).
void installFriendlyErrorWidget() {
  final debugBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (details) {
    if (kDebugMode) return debugBuilder(details);
    return const FriendlyErrorBox();
  };
}

/// The release-build stand-in for a widget that failed to build.
class FriendlyErrorBox extends StatelessWidget {
  const FriendlyErrorBox({super.key});

  @override
  Widget build(BuildContext context) {
    // Localizations may be missing if the failure is above MaterialApp.
    final t = Localizations.of<AppLocalizations>(context, AppLocalizations);
    return Material(
      color: AppColors.canvas,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.textSecondary, size: 32),
            const SizedBox(height: AppSpacing.sm),
            Text(
              t?.screenErrorTitle ?? 'This part of the screen could not be shown',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              t?.screenErrorMessage ?? 'Go back and try again. Your data is safe.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
