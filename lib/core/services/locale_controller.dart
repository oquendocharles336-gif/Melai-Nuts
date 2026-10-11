import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app language the person picked in Settings → Language.
///
/// `null` means "follow the phone's language" (English is used when the phone is
/// set to anything other than English or Filipino). The choice is saved on this
/// device only; it is a display preference, not account data.
class LocaleController extends ValueNotifier<Locale?> {
  LocaleController._() : super(null);

  static final LocaleController instance = LocaleController._();

  /// Languages the app is translated into (must match lib/l10n/app_*.arb).
  static const supportedCodes = <String>['en', 'fil'];

  static const _prefsKey = 'app_language';

  /// Reads the saved choice. Safe to call before runApp; a storage error keeps
  /// the phone's language.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = parse(prefs.getString(_prefsKey));
    } catch (_) {
      value = null;
    }
  }

  /// Saves and applies [code] ('en', 'fil', or null for the phone's language).
  Future<void> select(String? code) async {
    final next = parse(code);
    value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, next.languageCode);
      }
    } catch (_) {
      // Display preference only: the choice still applies until the app restarts.
    }
  }

  /// Unknown or empty codes mean "follow the phone".
  static Locale? parse(String? code) {
    final c = code?.trim().toLowerCase();
    if (c == null || c.isEmpty || !supportedCodes.contains(c)) return null;
    return Locale(c);
  }
}
