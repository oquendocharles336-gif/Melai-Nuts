import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/theme/app_theme.dart';
import 'package:melai_nuts/features/customer/screens/customer_home_screen.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

/// The Store dashboard must not overflow on a small phone or with large text.
/// (A RenderFlex overflow fails a widget test automatically.)
void main() {
  const sizes = {'small phone': Size(320, 568), 'phone': Size(390, 844)};

  Future<void> pumpStore(WidgetTester tester, Size size, double scale) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: const CustomerHomeScreen(),
    ));
    await tester.pump(const Duration(seconds: 2));
  }

  for (final size in sizes.entries) {
    for (final scale in const [1.0, 1.5]) {
      testWidgets('Store lays out on a ${size.key} at text scale $scale', (tester) async {
        await pumpStore(tester, size.value, scale);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Store shows the rewards card and all quick actions', (tester) async {
    await pumpStore(tester, sizes['phone']!, 1);
    expect(find.text('Golden Kernel Rewards'), findsOneWidget);
    for (final label in const ['Shop All', 'Categories', 'My Orders', 'Rewards']) {
      expect(find.text(label), findsWidgets);
    }
  });
}
