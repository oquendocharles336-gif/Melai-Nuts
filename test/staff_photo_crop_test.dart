import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/features/staff/widgets/staff_photo_crop_screen.dart';

/// A real PNG of [width] x [height] pixels (a wide photo, like most gallery pictures).
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.orange);
  canvas.drawCircle(Offset(width / 2, height / 2), height / 4, Paint()..color = Colors.blue);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  late Uint8List photo;
  Uint8List? result;
  var closed = false;

  Future<void> openCrop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    photo = (await tester.runAsync(() => _png(600, 300)))!;
    result = null;
    closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await StaffPhotoCropScreen.open(context, photo);
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The photo's size is read by the real image decoder.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  }

  testWidgets('the crop step shows the photo in a square with the circle guide', (tester) async {
    await openCrop(tester);

    expect(find.text('Move and zoom'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.textContaining('Pinch to zoom'), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.minScale, 1, reason: 'never smaller than the square: no empty corners');
    expect(viewer.boundaryMargin, EdgeInsets.zero, reason: 'cannot be dragged past its edges');

    // A 600x300 photo covering the square is twice as wide as it is tall, and
    // starts centred: shifted left by a quarter of its width.
    final side = tester.getSize(find.byType(InteractiveViewer)).width;
    final shift = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.getTranslation();
    expect(shift.x, closeTo(-side / 2, 0.5));
    expect(shift.y, closeTo(0, 0.5));
  });

  testWidgets('"Use photo" returns a square PNG of 512 pixels', (tester) async {
    await openCrop(tester);

    await tester.tap(find.text('Use photo'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNotNull);
    expect(result!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG signature');
    final size = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(result!);
      final frame = await codec.getNextFrame();
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    });
    expect(size, const Size(512, 512));
  });

  testWidgets('closing without choosing returns nothing', (tester) async {
    await openCrop(tester);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNull);
  });
}
