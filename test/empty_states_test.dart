import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/widgets/state_views.dart';
import 'package:melai_nuts/data/repositories/business_settings_repository.dart';
import 'package:melai_nuts/features/customer/widgets/online_payment_unavailable_notice.dart';
import 'package:melai_nuts/features/products/widgets/margin_indicator.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('an empty list says what is missing and offers the fix', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_app(DataStateView(
      isLoading: false,
      error: null,
      isEmpty: true,
      emptyTitle: 'No products yet.',
      emptyMessage: 'Add products under Products, then record stock with Receive Stock.',
      emptyActionLabel: 'Add product',
      onEmptyAction: () => tapped = true,
      builder: (_) => const Text('LIST'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('No products yet.'), findsOneWidget);
    expect(find.textContaining('Receive Stock'), findsOneWidget);
    expect(find.text('LIST'), findsNothing);
    await tester.tap(find.text('Add product'));
    expect(tapped, isTrue);
  });

  testWidgets('an error with nothing to show offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(_app(DataStateView(
      isLoading: false,
      error: Exception('SocketException: Failed host lookup'),
      isEmpty: true,
      emptyTitle: 'No orders yet',
      onRetry: () => retried = true,
      builder: (_) => const Text('LIST'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('No orders yet'), findsNothing, reason: 'an error is not shown as "empty"');
    final retry = find.textContaining(RegExp('retry|try again', caseSensitive: false));
    expect(retry, findsWidgets);
    await tester.tap(retry.first);
    expect(retried, isTrue);
  });

  testWidgets('data is shown when there is some', (tester) async {
    await tester.pumpWidget(_app(DataStateView(
      isLoading: false, error: null, isEmpty: false, emptyTitle: 'No orders yet', builder: (_) => const Text('LIST'),
    )));
    expect(find.text('LIST'), findsOneWidget);
  });

  testWidgets('online payment off: the database message is shown, no payment option', (tester) async {
    await tester.pumpWidget(_app(const OnlinePaymentUnavailableNotice(message: 'Paying online is paused.')));
    expect(find.text('Paying online is paused.'), findsOneWidget);
    expect(find.textContaining('GCash'), findsNothing);
  });

  testWidgets('a margin without the owner\'s line is shown without a rating', (tester) async {
    BusinessSettingsRepository.instance.current.value = BusinessSettings.notSet;
    await tester.pumpWidget(_app(const MarginIndicator(marginPercent: 62.5, profitPerUnit: 50)));
    await tester.pump();
    expect(find.textContaining('Margin 62.5%'), findsOneWidget);
    expect(find.textContaining('healthy-margin line not set'), findsOneWidget);

    BusinessSettingsRepository.instance.current.value = const BusinessSettings(healthyMarginPercent: 40);
    await tester.pump();
    expect(find.textContaining('healthy-margin line not set'), findsNothing);
  });
}
