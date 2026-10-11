import 'dart:convert';

import 'package:flutter/foundation.dart';

// Supabase configuration for Melai Nuts.
//
// The Supabase project URL + anon (public) key are NOT stored in source
// control. They are injected at build time, exactly like env/firebase.json:
//
//   flutter run \
//     --dart-define-from-file=env/firebase.json \
//     --dart-define-from-file=env/supabase.json
//
// Copy env/supabase.example.json to env/supabase.json (git-ignored) and fill
// in the values from your Supabase project's Settings > API page.
//
// The anon/publishable key is safe to ship in a client app — it identifies
// the project, not a privileged user. Every table it can reach is still
// protected by Postgres Row Level Security (see supabase/schema.sql); this
// key alone grants no access beyond what those policies allow. Never put
// the `service_role` (or any "secret") key in this app.
class SupabaseConfig {
  SupabaseConfig._();

  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// True when [key] is a privileged Supabase key that must NEVER be inside a
  /// client app: a new-style secret key (`sb_secret_...`) or a legacy JWT whose
  /// `role` claim is `service_role`. Only the anon / publishable key belongs
  /// here. The key itself is never logged or echoed.
  @visibleForTesting
  static bool isPrivilegedKey(String key) {
    final k = key.trim();
    if (k.startsWith('sb_secret_')) return true;
    final parts = k.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } catch (_) {
      return false; // not a decodable JWT (e.g. an sb_publishable_ key)
    }
  }

  static void requireConfigured() {
    // Refuse to run with a privileged key: it would bypass every Row Level
    // Security policy for anyone who unpacks the APK / IPA.
    if (isPrivilegedKey(anonKey)) {
      throw StateError(
        'SUPABASE_ANON_KEY holds a privileged (service_role / secret) key. '
        'Only the anon / publishable key may be used in the app. Replace it in '
        'env/supabase.json with the anon key from Supabase Settings > API, and '
        'rotate the privileged key you exposed. See SECURITY.md.',
      );
    }
    if (!isConfigured) {
      throw StateError(
        'Supabase URL/anon key are missing. Run with '
            '--dart-define-from-file=env/supabase.json '
            '(copy env/supabase.example.json first, fill in your project\'s '
            'values, and run supabase/schema.sql against that project). '
            'See SECURITY.md.',
      );
    }
  }
}