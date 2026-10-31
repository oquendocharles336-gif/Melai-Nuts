import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';

/// The Melai Nuts peanut-and-leaf brand mark.
///
/// Renders the prototype's SVG logo inside a circular cream badge. Used on
/// the splash screen, login screen, and app headers.
class AppLogo extends StatelessWidget {
  final double size;
  final bool showRing;

  /// Empty space around the mark, as a fraction of [size].
  final double inset;

  const AppLogo({super.key, this.size = 88, this.showRing = true, this.inset = 0.16});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        shape: BoxShape.circle,
        border: showRing
            ? Border.all(color: AppColors.border, width: 2)
            : null,
      ),
      padding: EdgeInsets.all(size * inset),
      child: SvgPicture.asset('assets/images/logo/melai_nuts_logo.svg'),
    );
  }
}
