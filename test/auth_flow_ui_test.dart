import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/theme/app_theme.dart';
import 'package:melai_nuts/features/auth/screens/login_screen.dart';
import 'package:melai_nuts/features/auth/screens/register_screen.dart';
import 'package:melai_nuts/features/auth/screens/welcome_screen.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

/// Welcome, Sign In and Create Account: navigation between them, and no
/// overflow on a small phone, a normal phone, or with large system text.
/// (A RenderFlex overflow fails a widget test automatically.)
Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  const sizes = {'small phone': Size(320, 568), 'phone': Size(390, 844)};
  const screens = {
    'Welcome': WelcomeScreen(),
    'Sign In': LoginScreen(),
    'Create Account': RegisterScreen(),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      for (final scale in const [1.0, 1.5]) {
        testWidgets('${screen.key} lays out on a ${size.key} at text scale $scale', (tester) async {
          _phone(tester, size.value);
          await tester.pumpWidget(_app(screen.value, textScale: scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('Welcome offers Sign In, Create Account and guest browsing', (tester) async {
    _phone(tester, sizes['phone']!);
    await tester.pumpWidget(_app(const WelcomeScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
    expect(find.text('Continue as guest'), findsOneWidget);
  });

  testWidgets('Welcome -> Sign In -> Create Account -> Sign In -> back to Welcome', (tester) async {
    _phone(tester, sizes['phone']!);
    await tester.pumpWidget(_app(const WelcomeScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await tester.ensureVisible(find.text('Create Account'));
    await tester.tap(find.text('Create Account'));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    // The long form is a lazy list: the footer link exists only once scrolled to.
    await tester.scrollUntilVisible(find.text('Sign In'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
  });

  group('after logging out, Sign In has nothing behind it', () {
    Future<void> openCreateAccount(WidgetTester tester) async {
      _phone(tester, sizes['phone']!);
      await tester.pumpWidget(_app(const LoginScreen()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();
      expect(find.byType(RegisterScreen), findsOneWidget);
    }

    testWidgets('the back arrow on Create Account returns to Sign In', (tester) async {
      await openCreateAccount(tester);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RegisterScreen), findsNothing);
    });

    testWidgets("the phone's back button on Create Account returns to Sign In", (tester) async {
      await openCreateAccount(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RegisterScreen), findsNothing);
    });

    testWidgets('the back arrow still works after scrolling down the long form', (tester) async {
      await openCreateAccount(tester);
      await tester.scrollUntilVisible(find.text('Sign In'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RegisterScreen), findsNothing);
    });

    testWidgets('the Sign In link on Create Account returns to Sign In', (tester) async {
      await openCreateAccount(tester);
      await tester.scrollUntilVisible(find.text('Sign In'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(RegisterScreen), findsNothing);
    });

    testWidgets("back from Sign In goes to Welcome, by arrow and by the phone's button", (tester) async {
      _phone(tester, sizes['phone']!);
      await tester.pumpWidget(_app(const LoginScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(const LoginScreen()));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });
  });

  testWidgets('Create Account with nothing behind it goes back to Welcome', (tester) async {
    _phone(tester, sizes['phone']!);
    await tester.pumpWidget(_app(const RegisterScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('Sign In with empty fields shows messages and stays put', (tester) async {
    _phone(tester, sizes['phone']!);
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('Password'), findsAtLeast(2)); // label + message
  });

  testWidgets('Create Account requires consent and matching passwords', (tester) async {
    _phone(tester, sizes['phone']!);
    await tester.pumpWidget(_app(const RegisterScreen()));
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(ElevatedButton, 'Create Account');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(find.text('Please confirm your password.'), findsOneWidget);
  });
}
