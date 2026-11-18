import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../data/models/cod_downpayment.dart';
import '../../../l10n/generated/app_localizations.dart';

/// The one-time first-order step at checkout: "Pay 50% now" / "Pay 100% now", with the
/// exact peso amounts from the server's quote. Same note styling as [DownpaymentNote].
class FirstOrderPaymentChoice extends StatelessWidget {
  final FirstOrderQuote quote;
  final FirstOrderChoice? selected;
  final bool isDelivery;
  final ValueChanged<FirstOrderChoice> onChanged;

  const FirstOrderPaymentChoice({
    super.key,
    required this.quote,
    required this.selected,
    required this.isDelivery,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.warningBg,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.waving_hand_outlined, size: 20, color: AppColors.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.firstOrderTitle, style: AppTextStyles.labelLg),
                    const SizedBox(height: 4),
                    Text(t.firstOrderExplain, style: AppTextStyles.bodySm),
                    const SizedBox(height: 4),
                    Text(t.firstOrderTimeLimit(quote.expiryMinutes), style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _ChoiceTile(
          icon: Icons.pie_chart_outline_rounded,
          title: t.firstOrderHalfTitle,
          subtitle: isDelivery
              ? t.firstOrderHalfDelivery(peso(quote.halfAmount), peso(quote.halfBalance))
              : t.firstOrderHalfPickup(peso(quote.halfAmount), peso(quote.halfBalance)),
          selected: selected == FirstOrderChoice.half,
          onTap: () => onChanged(FirstOrderChoice.half),
        ),
        const SizedBox(height: 8),
        _ChoiceTile(
          icon: Icons.check_circle_outline_rounded,
          title: t.firstOrderFullTitle,
          subtitle: t.firstOrderFullSubtitle(peso(quote.fullAmount)),
          selected: selected == FirstOrderChoice.full,
          onTap: () => onChanged(FirstOrderChoice.full),
        ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.6 : 1),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Icon(icon, color: AppColors.darkBrown),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTextStyles.labelLg),
                    Text(subtitle, style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
