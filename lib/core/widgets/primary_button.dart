import 'package:flutter/material.dart';

/// Standard full-width primary (filled) action button.
///
/// Use this everywhere a screen needs its main call-to-action, so button
/// sizing/shape/loading behavior stays consistent across every feature.
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
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: loading ? null : onPressed,
        icon: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon ?? Icons.arrow_forward_rounded, size: 18),
        label: Text(label),
      ),
    );
  }
}
