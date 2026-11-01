import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Melai Nuts brand mark: a smiling peanut on an orange badge. The badge
/// is part of the artwork, so it looks the same on any background.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/images/logo/melai_nuts_logo.svg',
      width: size,
      height: size,
      semanticsLabel: 'Melai Nuts',
    );
  }
}
