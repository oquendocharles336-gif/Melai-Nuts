import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'app_logo.dart';
import 'motion.dart';

/// The app's signature look: espresso and champagne gold, a faint gold lattice
/// instead of flat backgrounds, serif headings and gold hairlines.

/// Faint diamond lattice, drawn over a background.
class LatticePainter extends CustomPainter {
  final Color color;
  final double spacing;

  const LatticePainter({required this.color, this.spacing = 34});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;
    final reach = size.height + size.width;
    for (double d = -size.height; d < reach; d += spacing) {
      canvas.drawLine(Offset(d, 0), Offset(d + size.height, size.height), paint);
      canvas.drawLine(Offset(d + size.height, 0), Offset(d, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(LatticePainter oldDelegate) => oldDelegate.color != color || oldDelegate.spacing != spacing;
}

/// Champagne page background. Put a transparent [Scaffold] inside it.
class LuxeBackground extends StatelessWidget {
  final Widget child;

  const LuxeBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.canvas, AppColors.surfaceContainerHigh],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(painter: LatticePainter(color: AppColors.honeyDeep.withValues(alpha: 0.13))),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// Espresso page background with a gold lattice. Put a transparent [Scaffold]
/// inside it; the status bar icons turn light.
class LuxeDarkBackground extends StatelessWidget {
  final Widget child;

  const LuxeDarkBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: LatticePainter(color: AppColors.gold.withValues(alpha: 0.07))),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

/// A short gold line with a diamond in the middle.
class LuxeDivider extends StatelessWidget {
  final double width;

  const LuxeDivider({super.key, this.width = 120});

  @override
  Widget build(BuildContext context) {
    Widget line(Alignment begin, Alignment end) => Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: begin,
                end: end,
                colors: [AppColors.gold.withValues(alpha: 0), AppColors.gold],
              ),
            ),
          ),
        );
    return SizedBox(
      width: width,
      child: Row(
        children: [
          line(Alignment.centerLeft, Alignment.centerRight),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Transform.rotate(
              angle: 0.785398,
              child: Container(width: 6, height: 6, color: AppColors.gold),
            ),
          ),
          line(Alignment.centerRight, Alignment.centerLeft),
        ],
      ),
    );
  }
}

/// The logo inside a gold ring.
class LuxeCrest extends StatelessWidget {
  final double size;

  const LuxeCrest({super.key, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.gold, AppColors.honeyDeep, AppColors.gold],
        ),
        boxShadow: [BoxShadow(color: AppColors.gold.withValues(alpha: 0.28), blurRadius: 28)],
      ),
      child: AppLogo(size: size - 5, showRing: false, inset: 0.03),
    );
  }
}

/// Metallic gold main button, for dark backgrounds.
class LuxeGoldButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const LuxeGoldButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.gold, AppColors.honey, AppColors.honeyDeep],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54, minWidth: double.infinity),
            child: Center(
              child: Text(label, style: AppTextStyles.titleMd.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Black app bar with a faint lattice and a gold hairline, for the main tabs.
class LuxeAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;

  const LuxeAppBar({super.key, required this.title, this.actions});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title, style: AppTextStyles.headlineMd.copyWith(color: Colors.white)),
      flexibleSpace: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.gold.withValues(alpha: 0.5))),
          ),
          child: CustomPaint(painter: LatticePainter(color: AppColors.gold.withValues(alpha: 0.07))),
        ),
      ),
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

/// Sign In / Create Account layout: crest and serif title on espresso, with
/// the form on an ivory sheet that rises over it.
class LuxeAuthFrame extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final VoidCallback? onBack;

  const LuxeAuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return LuxeDarkBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs2, AppSpacing.xs, AppSpacing.lg),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: BackButton(color: AppColors.gold, onPressed: onBack),
                      ),
                      FadeSlideIn(
                        duration: const Duration(milliseconds: 500),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                          child: Column(
                            children: [
                              const LuxeCrest(size: 76),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                title,
                                textAlign: TextAlign.center,
                                style: AppTextStyles.display.copyWith(color: Colors.white),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              const LuxeDivider(),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                subtitle,
                                textAlign: TextAlign.center,
                                style: AppTextStyles.bodyMd.copyWith(color: AppColors.surfaceContainerHigh),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: FadeSlideIn(
                delay: const Duration(milliseconds: 120),
                offsetY: 40,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.ivory,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                    border: Border(top: BorderSide(color: AppColors.gold.withValues(alpha: 0.8), width: 1.5)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 28, AppSpacing.lg, AppSpacing.md),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
