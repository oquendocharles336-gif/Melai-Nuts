import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/theme/app_theme.dart';
import 'package:melai_nuts/core/widgets/app_text_field.dart';
import 'package:melai_nuts/features/auth/screens/register_screen.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

/// Create Account: each field turns red/green when it is LEFT, then follows the
/// text live. Untouched fields stay neutral. Messages come from ValidationUtils.
Widget _app() => MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RegisterScreen(),
    );

Finder _field(String label) => find.widgetWithText(AppTextField, label);
Finder _input(String label) => find.descendant(of: _field(label), matching: find.byType(TextFormField));
Finder _check(String label) => find.descendant(of: _field(label), matching: find.byIcon(Icons.check_circle_rounded));

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.enterText(_input(label), text);
  await tester.pump();
}

Future<void> _leave(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 2600); // tall: every field is on screen
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('untouched fields are neutral', (tester) async {
    await _open(tester);
    expect(find.text('Email address is required.'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('leaving Email empty -> red message', (tester) async {
    await _open(tester);
    await tester.tap(_input('Email Address'));
    await tester.pump();
    await _leave(tester);
    expect(find.text('Email address is required.'), findsOneWidget);
  });

  testWidgets('Email: "abc" red, then a valid address turns green live', (tester) async {
    await _open(tester);
    await _type(tester, 'Email Address', 'abc');
    expect(find.text('Please enter a valid email address (e.g. user@example.com).'), findsNothing); // not while first typing
    await _leave(tester);
    expect(find.text('Please enter a valid email address (e.g. user@example.com).'), findsOneWidget);
    await _type(tester, 'Email Address', 'me@example.com');
    expect(find.text('Please enter a valid email address (e.g. user@example.com).'), findsNothing);
    expect(_check('Email Address'), findsOneWidget);
  });

  testWidgets('Mobile: 12345 red, 09171234567 green', (tester) async {
    await _open(tester);
    await _type(tester, 'Mobile Number', '12345');
    await _leave(tester);
    expect(find.text('Enter your 11-digit mobile number, e.g. 09171234567.'), findsOneWidget);
    await _type(tester, 'Mobile Number', '09171234567');
    expect(_check('Mobile Number'), findsOneWidget);
  });

  testWidgets('Confirm Password re-validates when Password changes', (tester) async {
    await _open(tester);
    await _type(tester, 'Password', 'Strong#Pass123');
    await _leave(tester);
    await _type(tester, 'Confirm Password', 'Strong#Pass123');
    await _leave(tester);
    expect(_check('Confirm Password'), findsOneWidget);
    await _type(tester, 'Password', 'Strong#Pass1234');
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(_check('Confirm Password'), findsNothing);
  });

  testWidgets('Submitting empty marks every invalid field', (tester) async {
    await _open(tester);
    final submit = find.widgetWithText(ElevatedButton, 'Create Account');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('First Name is required.'), findsOneWidget);
    expect(find.text('Mobile number is required.'), findsOneWidget);
    expect(find.text('Email address is required.'), findsOneWidget);
    expect(find.text('Please confirm your password.'), findsOneWidget);
  });
}
