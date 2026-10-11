import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';

/// The owner's business settings (`public.get_business_settings()`, staff and
/// owners only; migration 20261018000000). Every value may be null = "Not set":
/// screens then show the plain figure without a rating, never an invented one.
class BusinessSettings {
  final int? restockThresholdDefault;
  final double? healthyMarginPercent;
  final double? defaultDailySalesTarget;

  const BusinessSettings({this.restockThresholdDefault, this.healthyMarginPercent, this.defaultDailySalesTarget});

  static const BusinessSettings notSet = BusinessSettings();

  factory BusinessSettings.fromJson(Map<String, dynamic>? j) {
    double? d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    return BusinessSettings(
      restockThresholdDefault: d(j?['restock_threshold_default'])?.round(),
      healthyMarginPercent: d(j?['healthy_margin_percent']),
      defaultDailySalesTarget: d(j?['default_daily_sales_target']),
    );
  }
}

class BusinessSettingsRepository {
  BusinessSettingsRepository._();
  static final BusinessSettingsRepository instance = BusinessSettingsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Last settings read; [BusinessSettings.notSet] until [load] succeeds.
  final ValueNotifier<BusinessSettings> current = ValueNotifier(BusinessSettings.notSet);
  Future<void>? _loading;

  /// Reads the settings once per session (call [load] with `force` after a change).
  Future<void> load({bool force = false}) {
    if (!force && _loading != null) return _loading!;
    return _loading = _fetch();
  }

  Future<void> _fetch() async {
    try {
      final result = await _client.rpc('get_business_settings');
      current.value = BusinessSettings.fromJson(result is Map ? Map<String, dynamic>.from(result) : null);
    } catch (e) {
      // Not readable (not staff, offline, migration missing): stay "Not set".
      _loading = null;
      debugPrint('business settings could not be read: $e');
    }
  }
}
