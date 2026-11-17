import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../data/models/product.dart';
import 'product_card.dart';

/// The product page's photos: every photo the owner uploaded on the admin
/// website (`products.images`, main photo first), swipeable, with dots and a
/// "2 / 3" counter. Tapping a photo opens it full screen (pinch to zoom).
///
/// With no uploaded photo it shows the product's usual placeholder (icon on
/// its colour), never a stock or made-up picture. When the owner changes the
/// photos the catalog reloads and [product] arrives with the new list; the
/// gallery then shows it, starting again at the first photo if the one being
/// looked at is gone.
class ProductPhotoGallery extends StatefulWidget {
  final Product product;
  final double aspectRatio;
  final BorderRadius borderRadius;

  const ProductPhotoGallery({
    super.key,
    required this.product,
    this.aspectRatio = 1.4,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppSpacing.radiusLg)),
  });

  @override
  State<ProductPhotoGallery> createState() => _ProductPhotoGalleryState();
}

class _ProductPhotoGalleryState extends State<ProductPhotoGallery> {
  final PageController _controller = PageController();
  int _index = 0;

  List<String> get _photos => widget.product.images.where((u) => u.isNotEmpty).toList();

  @override
  void didUpdateWidget(covariant ProductPhotoGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    final photos = _photos;
    if (_index >= photos.length || oldWidget.product.images.join('|') != widget.product.images.join('|')) {
      // The photo list changed (owner replaced / removed / reordered photos).
      final keep = _index < oldWidget.product.images.length ? oldWidget.product.images[_index] : null;
      final at = keep == null ? -1 : photos.indexOf(keep);
      _index = at >= 0 ? at : 0;
      if (_controller.hasClients) _controller.jumpToPage(_index);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openViewer(int start) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => _PhotoViewer(product: widget.product, photos: _photos, start: start),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = _photos;
    if (photos.isEmpty) {
      return AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: ProductThumbnail(product: widget.product, size: double.infinity, borderRadius: widget.borderRadius),
      );
    }

    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => Semantics(
                label: '${widget.product.name}, photo ${i + 1} of ${photos.length}',
                button: true,
                hint: 'Opens the photo full screen',
                child: GestureDetector(
                  onTap: () => _openViewer(i),
                  child: Hero(
                    tag: 'product-photo-${widget.product.id}-$i',
                    child: ProductThumbnail(
                      product: widget.product,
                      imageUrl: photos[i],
                      size: double.infinity,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
              ),
            ),
            if (photos.length > 1) ...[
              Positioned(
                top: 10,
                right: 10,
                child: _Counter(text: '${_index + 1} / ${photos.length}'),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: _Dots(count: photos.length, index: _index),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  final String text;
  const _Counter({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;
  const _Dots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 18 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: i == index ? AppColors.honey : Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(99),
                boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4)],
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-screen photos: swipe between them, pinch to zoom, close with ✕ or back.
class _PhotoViewer extends StatefulWidget {
  final Product product;
  final List<String> photos;
  final int start;
  const _PhotoViewer({required this.product, required this.photos, required this.start});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _controller = PageController(initialPage: widget.start);
  late int _index = widget.start;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.photos.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: n,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Hero(
                    tag: 'product-photo-${widget.product.id}-$i',
                    child: ProductThumbnail(
                      product: widget.product,
                      imageUrl: widget.photos[i],
                      size: double.infinity,
                      fit: BoxFit.contain,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
              ),
            ),
            if (n > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dots(count: n, index: _index),
                    const SizedBox(height: 8),
                    Text('${_index + 1} / $n', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}