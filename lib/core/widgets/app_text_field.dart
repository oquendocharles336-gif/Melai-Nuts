import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Characters allowed while typing (see `core/utils/input_rules.dart`).
  final List<TextInputFormatter>? inputFormatters;

  /// Hard limit on length (enforced while typing). A counter is shown only
  /// for multi-line fields.
  final int? maxLength;
  final int maxLines;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final FocusNode? focusNode;
  final bool enabled;
  final void Function(String)? onFieldSubmitted;

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
    this.inputFormatters,
    this.maxLength,
    this.maxLines = 1,
    this.autofillHints,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.focusNode,
    this.enabled = true,
    this.onFieldSubmitted,
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
          inputFormatters: widget.inputFormatters,
          maxLength: widget.maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          maxLines: widget.obscure ? 1 : widget.maxLines,
          autofillHints: widget.autofillHints,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          focusNode: widget.focusNode,
          enabled: widget.enabled,
          onFieldSubmitted: widget.onFieldSubmitted,
          decoration: InputDecoration(
            hintText: widget.hint,
            // Single-line fields enforce the limit silently; multi-line ones show a counter.
            counterText: widget.maxLines == 1 ? '' : null,
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
                    tooltip: _obscured ? 'Show password' : 'Hide password',
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
