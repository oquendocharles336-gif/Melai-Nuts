import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'app_logo.dart';
import 'motion.dart';

/// The app's signature look: warm cream pages, a sunny honey background for the
/// big moments, orange accents, a faint lattice and bold headings.

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

/// Cream page background. Put a transparent [Scaffold] inside it.
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

/// Sunny cream-to-honey page background, for splash, welcome and sign in. Put a
/// transparent [Scaffold] inside it; use dark text on it.
class LuxeSunBackground extends StatelessWidget {
  final Widget child;

  const LuxeSunBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.sunStart, AppColors.sunEnd],
          ),
        ),
        child: Stack(
          children: [
            const Positioned(top: -120, right: -90, child: _Glow(size: 340, opacity: 0.55)),
            const Positioned(bottom: -140, left: -110, child: _Glow(size: 320, opacity: 0.30)),
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: LatticePainter(color: AppColors.honeyDeep.withValues(alpha: 0.14))),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

/// A soft circle of sunlight.
class _Glow extends StatelessWidget {
  final double size;
  final double opacity;

  const _Glow({required this.size, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [AppColors.honey.withValues(alpha: opacity), AppColors.honey.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

/// A short orange line with a diamond in the middle.
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
                colors: [AppColors.primary.withValues(alpha: 0), AppColors.primary],
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
              child: Container(width: 6, height: 6, color: AppColors.primary),
            ),
          ),
          line(Alignment.centerRight, Alignment.centerLeft),
        ],
      ),
    );
  }
}

/// The logo with a soft glow.
class LuxeCrest extends StatelessWidget {
  final double size;

  const LuxeCrest({super.key, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: AppColors.primary.withValues(alpha: 0.30), blurRadius: size * 0.28, offset: Offset(0, size * 0.08)),
        ],
      ),
      child: AppLogo(size: size),
    );
  }
}

/// Orange main button with a soft shadow, for the sunny background.
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
          colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd],
        ),
        boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54, minWidth: double.infinity),
            child: Center(
              child: Text(label, style: AppTextStyles.titleMd.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Orange app bar with a faint lattice, for the main tabs.
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
            gradient: const LinearGradient(colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd]),
          ),
          child: CustomPaint(painter: LatticePainter(color: Colors.white.withValues(alpha: 0.06))),
        ),
      ),
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

/// Sign In / Create Account layout: logo and title on the sunny background, with
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
    // The phone's back button does the same as the arrow, also when there is
    // nothing behind this screen to go back to.
    return PopScope<Object?>(
      canPop: onBack == null || Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) onBack?.call();
      },
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) {
    return LuxeSunBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs2, AppSpacing.xs, AppSpacing.lg),
                  child: Column(
                    children: [
                      const SizedBox(height: 48), // room for the pinned back button
                      FadeSlideIn(
                        duration: const Duration(milliseconds: 500),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                          child: Column(
                            children: [
                              const LuxeCrest(size: 92),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                title,
                                textAlign: TextAlign.center,
                                style: AppTextStyles.display,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              const LuxeDivider(),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                subtitle,
                                textAlign: TextAlign.center,
                                style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted),
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
                    boxShadow: AppShadows.lg,
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
            // Pinned, so a long form never scrolls the way back out of reach.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.ivory.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                    boxShadow: AppShadows.sm,
                  ),
                  child: BackButton(color: AppColors.primaryDark, onPressed: onBack),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
