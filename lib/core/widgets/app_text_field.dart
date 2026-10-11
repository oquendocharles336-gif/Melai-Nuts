import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Standard labeled text field used across auth & form screens.
class AppTextField extends StatefulWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool obscure;
  final IconData? prefixIcon;
  final Widget? trailing;
  final TextInputType? keyboardType;
  final String? helperText;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;

  const AppTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.prefixIcon,
    this.trailing,
    this.keyboardType,
    this.helperText,
    this.validator,
    this.onChanged,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: AppTextStyles.labelLg),
        const SizedBox(height: 6),
        TextFormField(
          controller: widget.controller,
          obscureText: _obscured,
          keyboardType: widget.keyboardType,
          style: AppTextStyles.bodyLg,
          validator: widget.validator,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: widget.prefixIcon != null
                ? Icon(
                    widget.prefixIcon,
                    size: 20,
                    color: AppColors.textSecondary,
                  )
                : null,
            suffixIcon: widget.obscure
                ? IconButton(
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  )
                : widget.trailing,
          ),
        ),
        if (widget.helperText != null) ...[
          const SizedBox(height: 6),
          Text(widget.helperText!, style: AppTextStyles.bodySm),
        ],
      ],
    );
  }
}
