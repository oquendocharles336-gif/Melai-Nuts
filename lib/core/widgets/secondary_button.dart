import 'package:flutter/material.dart';

/// Standard full-width secondary (outlined) action button.
class SecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: icon == null
          ? OutlinedButton(onPressed: onPressed, child: Text(label))
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon, size: 18),
              label: Text(label),
            ),
    );
  }
}
