import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Shown in place of the online-payment option while it is off.
class OnlinePaymentUnavailableNotice extends StatelessWidget {
  final String message;

  const OnlinePaymentUnavailableNotice({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).onlinePaymentUnavailableLabel(message),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: AppTextStyles.bodySm)),
          ],
        ),
      ),
    );
  }
}
