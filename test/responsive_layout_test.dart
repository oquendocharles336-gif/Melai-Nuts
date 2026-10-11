import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/widgets/confirm_dialog.dart';
import 'package:melai_nuts/core/widgets/list_tools.dart';
import 'package:melai_nuts/features/legal/screens/legal_document_screen.dart';
import 'package:melai_nuts/features/legal/widgets/terms_consent_field.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

/// Phone (360), tablet (768) and desktop/web (1280) widths: the shared
/// widgets added for the panel criteria must lay out without overflow.
/// (A RenderFlex overflow fails a widget test automatically.)
const _widths = <double>[360, 768, 1280];

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _atWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final width in _widths) {
    testWidgets('Terms screen at ${width.toInt()} px', (tester) async {
      await _atWidth(tester, width);
      await tester.pumpWidget(_app(const TermsAndConditionsScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('search + sort/filter header and consent at ${width.toInt()} px', (tester) async {
      await _atWidth(tester, width);
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppSearchBar(
              onChanged: (_) {},
              trailing: SortFilterButton(onPressed: () {}, active: true),
            ),
            ActiveFilterChips<int>(
              query: const ListQuery(sortId: 'a', filters: {'status': 'x'}),
              groups: const [
                FilterGroup('status', 'Status', [FilterChoice('x', 'A rather long filter label', null)]),
              ],
              onChanged: (_) {},
            ),
            Form(child: TermsConsentField(onChanged: (_) {})),
          ],
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirm dialog: Cancel is the safe default and returns false', (tester) async {
    bool? result;
    await tester.pumpWidget(_app(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => result = await ConfirmDialog.delete(context, 'this address'),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
