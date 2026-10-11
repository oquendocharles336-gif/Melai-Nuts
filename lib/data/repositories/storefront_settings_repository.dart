import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';

/// Customer-facing switches the owner sets on Business settings
/// (`public.get_storefront_settings()`, migration 20261023000000).
class StorefrontSettings {
  /// Show "Only N left" when a branch has 1..N units. Null = Not set: never shown.
  final int? lowStockBadgeQty;

  const StorefrontSettings({this.lowStockBadgeQty});

  static const StorefrontSettings notSet = StorefrontSettings();

  factory StorefrontSettings.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    final v = j['low_stock_badge_qty'];
    final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    return StorefrontSettings(lowStockBadgeQty: n != null && n > 0 ? n : null);
  }
}

class StorefrontSettingsRepository {
  StorefrontSettingsRepository._();
  static final StorefrontSettingsRepository instance = StorefrontSettingsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  StorefrontSettings current = StorefrontSettings.notSet;

  /// Refreshes [current]. On failure the badge is simply not shown (nothing invented).
  Future<StorefrontSettings> load() async {
    try {
      current = StorefrontSettings.fromJson(await _client.rpc('get_storefront_settings'));
    } catch (e, st) {
      AppErrors.report(e, st, 'storefront_settings:load');
      current = StorefrontSettings.notSet;
    }
    return current;
  }
}
