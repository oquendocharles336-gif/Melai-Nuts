import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/repositories/business_settings_repository.dart';
import 'package:melai_nuts/features/products/widgets/margin_indicator.dart';

void main() {
  test('settings the owner never entered are null ("Not set")', () {
    final s = BusinessSettings.fromJson({'restock_threshold_default': null, 'healthy_margin_percent': null});
    expect(s.restockThresholdDefault, isNull);
    expect(s.healthyMarginPercent, isNull);
    expect(s.defaultDailySalesTarget, isNull);
    expect(BusinessSettings.fromJson(null).healthyMarginPercent, isNull);
  });

  test('the owner\'s values are read as they are', () {
    final s = BusinessSettings.fromJson({'restock_threshold_default': 15, 'healthy_margin_percent': '42.5', 'default_daily_sales_target': 5000});
    expect(s.restockThresholdDefault, 15);
    expect(s.healthyMarginPercent, 42.5);
    expect(s.defaultDailySalesTarget, 5000);
  });

  test('a margin is rated only against the owner\'s line, never a built-in 50 %', () {
    expect(rateMargin(80, null), isNull);
    expect(rateMargin(10, null), isNull);
    expect(rateMargin(40, 40), MarginRating.healthy);
    expect(rateMargin(39.9, 40), MarginRating.low);
  });
}
