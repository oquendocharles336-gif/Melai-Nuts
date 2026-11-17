import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/theme/app_theme.dart';
import 'package:melai_nuts/features/legal/widgets/terms_consent_field.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

/// The consent box on Create Account cannot be ticked until the Terms and
/// Conditions and the Privacy Policy were both opened.
Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Form(child: child)),
    );

void main() {
  testWidgets('consent box starts locked, with a hint to open both documents', (tester) async {
    var agreed = false;
    await tester.pumpWidget(_app(TermsConsentField(onChanged: (v) => agreed = v)));
    await tester.pumpAndSettle();

    final box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.onChanged, isNull); // disabled
    expect(box.value, isFalse);
    expect(find.textContaining('You can tick the box after viewing both'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(agreed, isFalse);
  });

  testWidgets('a box that is already ticked stays usable', (tester) async {
    await tester.pumpWidget(_app(TermsConsentField(initialValue: true, onChanged: (_) {})));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNotNull);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });
}
