import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// The Melai Nuts peanut-and-leaf brand mark.
///
/// Renders the prototype's SVG logo inside a circular cream badge. Used on
/// the splash screen, login screen, and app headers.
class AppLogo extends StatelessWidget {
  final double size;
  final bool showRing;

  const AppLogo({super.key, this.size = 88, this.showRing = true});

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
        boxShadow: showRing ? AppShadows.sm : null,
      ),
      padding: EdgeInsets.all(size * 0.16),
      child: SvgPicture.asset('assets/images/logo/melai_nuts_logo.svg'),
    );
  }
}
