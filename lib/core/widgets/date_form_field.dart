import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A date chosen with the date picker, as a real form field: it takes part in
/// `Form.validate()` and shows its message under the field (e.g. "Expiration
/// date cannot be in the past."). Pair with `ValidationUtils.validateDateValue`.
class DateFormField extends FormField<DateTime> {
  DateFormField({
    super.key,
    required String label,
    required DateTime firstDate,
    required DateTime lastDate,
    super.initialValue,
    super.validator,
    ValueChanged<DateTime>? onChanged,
    String placeholder = 'Choose a date',
  }) : super(
          builder: (state) {
            final value = state.value;
            Future<void> pick() async {
              final now = DateTime.now();
              var initial = value ?? now;
              if (initial.isBefore(firstDate)) initial = firstDate;
              if (initial.isAfter(lastDate)) initial = lastDate;
              final picked = await showDatePicker(
                context: state.context,
                initialDate: initial,
                firstDate: firstDate,
                lastDate: lastDate,
                helpText: label,
              );
              if (picked == null) return;
              state.didChange(picked);
              state.validate();
              onChanged?.call(picked);
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  button: true,
                  label: '$label: ${value == null ? placeholder : formatDate(value)}',
                  child: InkWell(
                    onTap: pick,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                        border: Border.all(
                          color: state.hasError
                              ? AppColors.error
                              : (value == null ? AppColors.warning : AppColors.border),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.textSecondary),
                          const SizedBox(width: 10),
                          Expanded(child: Text(label, style: AppTextStyles.bodyMd)),
                          Text(value == null ? placeholder : formatDate(value), style: AppTextStyles.labelLg),
                        ],
                      ),
                    ),
                  ),
                ),
                if (state.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm, top: AppSpacing.xs2),
                    child: Text(
                      state.errorText!,
                      style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                    ),
                  ),
              ],
            );
          },
        );

  static String formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
