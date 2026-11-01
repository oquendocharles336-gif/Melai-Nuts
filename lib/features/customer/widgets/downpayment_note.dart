import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Why a pickup order asks for a downpayment. The share and the days always come
/// from the server's values, never from this text.
class DownpaymentNote extends StatelessWidget {
  /// The percent the owner set, or null when it is a fixed amount.
  final double? percent;

  /// The amount due online, shown when there is no percent.
  final double amount;
  final int pickupDays;

  const DownpaymentNote({super.key, this.percent, required this.amount, required this.pickupDays});

  /// "30%" (or "12.5%"), or "₱100.00" for a fixed amount.
  static String shareLabel({double? percent, required double amount}) {
    if (percent == null) return '₱${amount.toStringAsFixed(2)}';
    final whole = percent == percent.roundToDouble();
    return '${whole ? percent.toStringAsFixed(0) : percent.toString()}%';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 20, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t.downpaymentNote(shareLabel(percent: percent, amount: amount), t.downpaymentDays(pickupDays)),
              style: AppTextStyles.bodySm,
            ),
          ),
        ],
      ),
    );
  }
}
