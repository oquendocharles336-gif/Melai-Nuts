import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/locale_controller.dart';
import 'package:melai_nuts/features/customer/widgets/online_payment_unavailable_notice.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

Map<String, dynamic> _arb(String code) =>
    jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync()) as Map<String, dynamic>;

Set<String> _keys(Map<String, dynamic> arb) => arb.keys.where((k) => !k.startsWith('@')).toSet();

final _placeholder = RegExp(r'\{(\w+)\}');

void main() {
  test('English and Filipino have exactly the same messages', () {
    final en = _arb('en');
    final fil = _arb('fil');
    expect(_keys(fil), _keys(en));
    for (final k in _keys(en)) {
      expect((fil[k] as String).trim(), isNotEmpty, reason: 'Filipino "$k" is empty');
      final enVars = _placeholder.allMatches(en[k] as String).map((m) => m[1]).toSet();
      final filVars = _placeholder.allMatches(fil[k] as String).map((m) => m[1]).toSet();
      expect(filVars, enVars, reason: 'placeholders differ for "$k"');
      if (enVars.isNotEmpty) expect(en['@$k'], isNotNull, reason: '"$k" needs placeholder metadata');
    }
  });

  test('the language setting accepts only translated languages', () {
    expect(LocaleController.parse('fil'), const Locale('fil'));
    expect(LocaleController.parse(' EN '), const Locale('en'));
    expect(LocaleController.parse('es'), isNull);
    expect(LocaleController.parse(''), isNull);
    expect(LocaleController.parse(null), isNull);
  });

  testWidgets('Filipino strings render when Filipino is chosen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fil'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) => Text(AppLocalizations.of(context).cashOnDelivery)),
    ));
    expect(find.text(_arb('fil')['cashOnDelivery'] as String), findsOneWidget);
  });

  testWidgets('the online-payment notice reads the owner message in either language', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fil'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: OnlinePaymentUnavailableNotice(message: 'Sarado muna.')),
    ));
    expect(find.bySemanticsLabel(RegExp('Sarado muna')), findsWidgets);
    handle.dispose();
  });
}
