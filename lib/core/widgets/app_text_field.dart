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

  /// Opt-in live feedback (used by the Create Account form). The field stays
  /// neutral until the person has left it once (or the form was submitted);
  /// from then on it re-validates on every keystroke: red border + message
  /// when [validator] returns an error, green border + check when it passes.
  /// Empty optional fields (validator returns null for '') stay neutral.
  final bool liveValidate;

  /// Re-validates this field (once touched) whenever [revalidateOn] notifies,
  /// e.g. Confirm Password listening to the Password controller.
  final Listenable? revalidateOn;

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
    this.liveValidate = false,
    this.revalidateOn,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscure;

  // --- live validation (only used when widget.liveValidate is true) ---
  final _fieldKey = GlobalKey<FormFieldState<String>>();
  FocusNode? _ownNode;
  FocusNode? _node;
  TextEditingController? _listenedController;
  Listenable? _listenedRevalidate;
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liveValidate != widget.liveValidate ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.controller != widget.controller ||
        oldWidget.revalidateOn != widget.revalidateOn) {
      _detach();
      _attach();
    }
  }

  @override
  void dispose() {
    _detach();
    _ownNode?.dispose();
    super.dispose();
  }

  void _attach() {
    if (!widget.liveValidate) return;
    _node = widget.focusNode ?? (_ownNode ??= FocusNode());
    _node!.addListener(_onFocusChanged);
    _listenedController = widget.controller..addListener(_onValueChanged);
    _listenedRevalidate = widget.revalidateOn?..addListener(_onValueChanged);
  }

  void _detach() {
    _node?.removeListener(_onFocusChanged);
    _listenedController?.removeListener(_onValueChanged);
    _listenedRevalidate?.removeListener(_onValueChanged);
    _node = null;
    _listenedController = null;
    _listenedRevalidate = null;
  }

  /// The person left the box: validate it now (this also marks it touched).
  void _onFocusChanged() {
    if (_node?.hasFocus ?? true) return;
    Future<void>.microtask(() {
      if (mounted) _fieldKey.currentState?.validate();
    });
  }

  /// Typing, or a field this one depends on changed: refresh the green/red
  /// state, but only for fields the person has already left once.
  void _onValueChanged() {
    if (_touched && mounted) setState(() {});
  }

  /// Wraps the caller's validator. Any validation run (blur, submit) means the
  /// field counts as touched from now on.
  String? _validate(String? value) {
    final result = widget.validator?.call(value);
    if (widget.liveValidate && !_touched) {
      _touched = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return result;
  }

  bool get _showValid {
    final validator = widget.validator;
    if (!widget.liveValidate || !_touched || validator == null) return false;
    final text = widget.controller.text;
    if (text.trim().isEmpty) return false; // empty optional field: neutral
    return validator(text) == null;
  }

  InputBorder? _greenBorder(InputBorder? base, double width) =>
      base?.copyWith(borderSide: BorderSide(color: AppColors.success, width: width));

  @override
  Widget build(BuildContext context) {
    final valid = _showValid;
    final theme = Theme.of(context).inputDecorationTheme;
    final toggle = widget.obscure
        ? IconButton(
            icon: Icon(
              _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              size: 20,
              color: AppColors.textSecondary,
            ),
            tooltip: _obscured ? 'Show password' : 'Hide password',
            onPressed: () => setState(() => _obscured = !_obscured),
          )
        : widget.trailing;
    final check = valid
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.check_circle_rounded, size: 20, color: AppColors.success, semanticLabel: 'Valid'),
          )
        : null;
    final Widget? suffix = (check != null && toggle != null)
        ? Row(mainAxisSize: MainAxisSize.min, children: [check, toggle])
        : (toggle ?? check);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: AppTextStyles.labelMd),
        const SizedBox(height: 6),
        TextFormField(
          key: widget.liveValidate ? _fieldKey : null,
          controller: widget.controller,
          obscureText: _obscured,
          keyboardType: widget.keyboardType,
          style: AppTextStyles.bodyLg,
          validator: widget.liveValidate && widget.validator != null ? _validate : widget.validator,
          autovalidateMode: widget.liveValidate && _touched ? AutovalidateMode.always : null,
          onChanged: widget.onChanged,
          inputFormatters: widget.inputFormatters,
          maxLength: widget.maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          maxLines: widget.obscure ? 1 : widget.maxLines,
          autofillHints: widget.autofillHints,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          focusNode: widget.liveValidate ? _node : widget.focusNode,
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
            suffixIcon: suffix,
            // Green only once validated; errors keep the theme's red borders.
            enabledBorder: valid ? _greenBorder(theme.enabledBorder, 1.2) : null,
            focusedBorder: valid ? _greenBorder(theme.focusedBorder, 1.4) : null,
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
