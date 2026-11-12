import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_spacing.dart';
import '../utils/validation_utils.dart';
import 'app_text_field.dart';

/// First Name and Last Name.
class PersonNameFields extends StatelessWidget {
  final TextEditingController first;
  final TextEditingController last;

  /// Each part's limit, so the composed name fits [InputLimits.name].
  static const int _partLimit = 23;

  const PersonNameFields({
    super.key,
    required this.first,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppTextField(
          label: 'First Name',
          controller: first,
          hint: 'Juan',
          keyboardType: TextInputType.name,
          textCapitalization: TextCapitalization.words,
          autofillHints: const [AutofillHints.givenName],
          textInputAction: TextInputAction.next,
          maxLength: _partLimit,
          validator: (v) => ValidationUtils.validateName(v, 'First Name'),
        ),
        const SizedBox(height: AppSpacing.md),
        AppTextField(
          label: 'Last Name',
          controller: last,
          hint: 'Dela Cruz',
          keyboardType: TextInputType.name,
          textCapitalization: TextCapitalization.words,
          autofillHints: const [AutofillHints.familyName],
          textInputAction: TextInputAction.next,
          maxLength: _partLimit,
          validator: (v) => ValidationUtils.validateName(v, 'Last Name'),
        ),
      ],
    );
  }
}
