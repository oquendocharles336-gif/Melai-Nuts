import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../l10n/generated/app_localizations.dart';

/// "I have read and agree to the Terms and Conditions and the Privacy Policy."
///
/// * Starts **unticked**: consent is an active choice, never pre-filled.
/// * "Terms and Conditions" and "Privacy Policy" are tappable links that open
///   the full documents.
/// * The box is **locked until both documents have been opened**: nobody can
///   agree to something they have not looked at. A hint under the box says
///   which document is still to be opened.
/// * It is a [FormField], so `Form.validate()` / `FormUtils.validateAndFocus`
///   show an inline error **under the checkbox** when it is not ticked —
///   submit is never silently disabled.
class TermsConsentField extends FormField<bool> {
  TermsConsentField({
    super.key,
    required ValueChanged<bool> onChanged,
    bool initialValue = false,
  }) : super(
          initialValue: initialValue,
          // The text is localized in the builder (validators have no context).
          validator: (v) => v == true ? null : 'consent-required',
          builder: (state) => _TermsConsentBody(state: state, onChanged: onChanged),
        );
}

class _TermsConsentBody extends StatefulWidget {
  const _TermsConsentBody({required this.state, required this.onChanged});

  final FormFieldState<bool> state;
  final ValueChanged<bool> onChanged;

  @override
  State<_TermsConsentBody> createState() => _TermsConsentBodyState();
}

class _TermsConsentBodyState extends State<_TermsConsentBody> {
  late final TapGestureRecognizer _termsTap = TapGestureRecognizer()
    ..onTap = () => _open(AppRoutes.legalTerms);
  late final TapGestureRecognizer _privacyTap = TapGestureRecognizer()
    ..onTap = () => _open(AppRoutes.legalPrivacy);

  // The box unlocks only after each document was opened from this form.
  // (A box that arrives already ticked was agreed to earlier, so it stays usable.)
  late bool _termsViewed = widget.state.value ?? false;
  late bool _privacyViewed = widget.state.value ?? false;

  bool get _unlocked => _termsViewed && _privacyViewed;

  void _open(String route) {
    setState(() {
      if (route == AppRoutes.legalTerms) _termsViewed = true;
      if (route == AppRoutes.legalPrivacy) _privacyViewed = true;
    });
    Navigator.of(context).pushNamed(route);
  }

  /// What is still to be opened, or null once the box is unlocked.
  String? _lockedHint(AppLocalizations t) {
    if (_unlocked) return null;
    if (!_termsViewed && !_privacyViewed) return t.consentViewBoth;
    return t.consentViewOne(_termsViewed ? t.legalPrivacyTitle : t.legalTermsTitle);
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  void _set(bool value) {
    widget.state.didChange(value);
    widget.onChanged(value);
    if (widget.state.hasError) widget.state.validate();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final checked = widget.state.value ?? false;
    final lockedHint = _lockedHint(t);
    final link = AppTextStyles.bodySm.copyWith(
      color: AppColors.primary,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: checked,
              isError: widget.state.hasError,
              activeColor: AppColors.success, // green once ticked
              // Greyed out and not tickable until both documents were opened.
              onChanged: _unlocked ? (v) => _set(v ?? false) : null,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text.rich(
                  TextSpan(
                    style: AppTextStyles.bodySm,
                    children: [
                      TextSpan(text: t.consentPrefix),
                      TextSpan(text: t.legalTermsTitle, style: link, recognizer: _termsTap),
                      TextSpan(text: t.consentAnd),
                      TextSpan(text: t.legalPrivacyTitle, style: link, recognizer: _privacyTap),
                      TextSpan(text: t.consentSuffix),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (lockedHint != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sm, top: AppSpacing.xs2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: AppSpacing.xs2),
                Expanded(
                  child: Text(
                    lockedHint,
                    style: AppTextStyles.bodySm.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (widget.state.hasError)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sm, top: AppSpacing.xs2),
            child: Text(
              t.consentRequired,
              style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
            ),
          ),
      ],
    );
  }
}

/// An optional, separate opt-in (e.g. "Send me order updates"). Unticked by
/// default and never required to submit.
class OptionalConsentTile extends StatelessWidget {
  const OptionalConsentTile({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: value,
            activeColor: AppColors.primary,
            onChanged: (v) => onChanged(v ?? false),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(!value),
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(label, style: AppTextStyles.bodySm),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
