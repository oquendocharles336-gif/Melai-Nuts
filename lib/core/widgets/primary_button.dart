import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Standard full-width primary (filled) action button.
///
/// Use this everywhere a screen needs its main call-to-action, so button
/// sizing/shape/loading behavior stays consistent across every feature.
/// It presses down slightly, keeps its colour while busy (with a white
/// spinner, announced to screen readers) and is at least 52 px tall.
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        // Busy is not "disabled": keep the brand colour so the step does not look broken.
        style: loading
            ? ElevatedButton.styleFrom(
                disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.85),
                disabledForegroundColor: AppColors.onPrimary,
              )
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onPrimary),
              ),
              const SizedBox(width: 8),
            ] else if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
    return Semantics(
      liveRegion: loading,
      child: loading || onPressed == null ? button : _PressScale(child: button),
    );
  }
}

/// Shrinks its child a little while a finger is down. Uses raw pointer events,
/// so the button keeps its own tap, ripple and keyboard handling.
class _PressScale extends StatefulWidget {
  final Widget child;

  const _PressScale({required this.child});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !still ? 0.98 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
