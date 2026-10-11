import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import 'offline_read_cache_client.dart';
import 'supabase_token.dart';

/// Bootstraps the Supabase client and makes every request identify itself
/// as the signed-in Firebase user.
///
/// Firebase stays the identity provider (sign-in, email verification,
/// password reset). Supabase is configured as a "Third-Party Auth" consumer
/// of Firebase (Supabase Dashboard > Authentication > Sign In / Providers >
/// Third Party Auth > Firebase, using this app's Firebase project ID) so
/// that Postgres Row Level Security policies can check the caller's Firebase
/// UID directly via `auth.jwt() ->> 'sub'` — no Supabase Auth account, no
/// service-role key on the client, ever.
///
/// [accessToken] below is the hook `Supabase.initialize` calls before every
/// request to fetch the current bearer token; we hand it the caller's live
/// Firebase ID token. When nobody is signed in it returns null and requests
/// go out under the `anon` key, which is enough for the public, read-only
/// data (catalog, categories, rewards) per supabase/schema.sql's policies.
class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    SupabaseConfig.requireConfigured();

    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.anonKey,
      // Durable read-through cache for PostgREST *reads only* so previously
      // fetched data stays readable (and is labelled as saved data) when the
      // network is down. Writes and mutating RPCs pass through untouched —
      // see OfflineReadCacheClient.
      httpClient: OfflineReadCacheClient(),
      accessToken: SupabaseToken.fetch,
    );

    _initialized = true;
  }

  SupabaseClient get client => Supabase.instance.client;
}