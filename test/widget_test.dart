// Basic smoke test: the app boots to the splash screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/app.dart';
import 'package:melai_nuts/core/constants/app_constants.dart';

void main() {
  testWidgets('Splash screen smoke test', (WidgetTester tester) async {
    // The app is designed for phones. flutter_test's default surface is
    // 800x600, which is shorter than the splash column and would report a
    // layout overflow that no real device shows. Use a phone-sized surface.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final semantics = tester.ensureSemantics();

    // Build our app and trigger a frame.
    await tester.pumpWidget(const MelaiNutsApp());

    // The name animates in letter by letter, and is announced as one label.
    expect(find.bySemanticsLabel(AppConstants.appName), findsOneWidget);
    semantics.dispose();
  });
}
