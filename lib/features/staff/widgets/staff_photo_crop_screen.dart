import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Lets a staff member move and zoom a picked photo inside a square before it
/// is uploaded. Pops with PNG bytes of that square ([outputSize] pixels a
/// side), or null when cancelled.
///
/// Built on [InteractiveViewer] only, so no extra package or native setup.
/// The photo always covers the whole square: it starts centred at the
/// smallest size that fills it, can be zoomed in up to [maxZoom] times, and
/// cannot be dragged past its own edges.
class StaffPhotoCropScreen extends StatefulWidget {
  final Uint8List bytes;
  final int outputSize;
  final double maxZoom;

  const StaffPhotoCropScreen({
    super.key,
    required this.bytes,
    this.outputSize = 512,
    this.maxZoom = 5,
  });

  /// Opens the crop step full screen and returns the cropped square, or null.
  static Future<Uint8List?> open(BuildContext context, Uint8List bytes) {
    return Navigator.of(context, rootNavigator: true).push<Uint8List>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => StaffPhotoCropScreen(bytes: bytes)),
    );
  }

  @override
  State<StaffPhotoCropScreen> createState() => _StaffPhotoCropScreenState();
}

class _StaffPhotoCropScreenState extends State<StaffPhotoCropScreen> {
  final GlobalKey _square = GlobalKey();
  final TransformationController _controller = TransformationController();

  /// The photo's own size in pixels, once decoded.
  Size? _photoSize;
  bool _unreadable = false;
  bool _saving = false;

  /// The square's side the current transform was centred for.
  double? _centredFor;

  @override
  void initState() {
    super.initState();
    _readSize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _readSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (mounted) setState(() => _photoSize = size);
    } catch (_) {
      if (mounted) setState(() => _unreadable = true);
    }
  }

  /// The photo scaled to just cover a [side] x [side] square.
  Size _coverSize(double side) {
    final photo = _photoSize!;
    final scale = math.max(side / photo.width, side / photo.height);
    return Size(photo.width * scale, photo.height * scale);
  }

  /// Starts with the photo centred in the square.
  void _centre(double side) {
    if (_centredFor == side) return;
    final first = _centredFor == null;
    _centredFor = side;
    final cover = _coverSize(side);
    final centred = Matrix4.translationValues(-(cover.width - side) / 2, -(cover.height - side) / 2, 0);
    if (first) {
      _controller.value = centred; // before the viewer listens to it
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.value = centred;
      });
    }
  }

  Future<void> _usePhoto() async {
    final boundary = _square.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    setState(() => _saving = true);
    try {
      final image = await boundary.toImage(pixelRatio: widget.outputSize / boundary.size.width);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('empty image');
      if (!mounted) return;
      Navigator.of(context).pop(data.buffer.asUint8List());
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not prepare the picture. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _photoSize != null && !_saving;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Move and zoom'),
        actions: [
          TextButton(
            onPressed: ready ? _usePhoto : null,
            child: Text(
              _saving ? 'Saving…' : 'Use photo',
              style: AppTextStyles.labelLg.copyWith(color: ready ? AppColors.honey : Colors.white38),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: Center(child: _body())),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
              child: Text(
                'Pinch to zoom and drag to move. The circle shows what others will see.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd.copyWith(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_unreadable) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          "This picture can't be opened. Please choose another one.",
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMd.copyWith(color: Colors.white),
        ),
      );
    }
    if (_photoSize == null) return const CircularProgressIndicator(color: Colors.white);
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(math.min(constraints.maxWidth, constraints.maxHeight) - 2 * AppSpacing.md, 420.0);
        _centre(side);
        final cover = _coverSize(side);
        return SizedBox(
          width: side,
          height: side,
          child: Stack(
            children: [
              RepaintBoundary(
                key: _square,
                child: ClipRect(
                  child: InteractiveViewer(
                    transformationController: _controller,
                    constrained: false,
                    minScale: 1,
                    maxScale: widget.maxZoom,
                    boundaryMargin: EdgeInsets.zero,
                    child: Image.memory(
                      widget.bytes,
                      width: cover.width,
                      height: cover.height,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
              IgnorePointer(child: CustomPaint(size: Size.square(side), painter: const _CircleGuide())),
            ],
          ),
        );
      },
    );
  }
}

/// Darkens the corners outside the circle and outlines it.
class _CircleGuide extends CustomPainter {
  const _CircleGuide();

  @override
  void paint(Canvas canvas, Size size) {
    final square = Offset.zero & size;
    final circle = Path()..addOval(square.deflate(1));
    final outside = Path.combine(PathOperation.difference, Path()..addRect(square), circle);
    canvas.drawPath(outside, Paint()..color = Colors.black54);
    canvas.drawPath(
      circle,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CircleGuide oldDelegate) => false;
}
