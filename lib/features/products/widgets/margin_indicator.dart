import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/repositories/business_settings_repository.dart';

/// Rates a margin against the owner's "healthy margin" setting.
/// `null` = no rating (the setting is not set); never a built-in line.
enum MarginRating { healthy, low }

MarginRating? rateMargin(double marginPercent, double? healthyFromPercent) {
  if (healthyFromPercent == null) return null;
  return marginPercent >= healthyFromPercent ? MarginRating.healthy : MarginRating.low;
}

/// "Margin X% (₱Y profit/unit)" coloured by [rateMargin]; neutral while the
/// owner has not set a healthy-margin line (Business settings).
class MarginIndicator extends StatefulWidget {
  final double marginPercent;
  final double profitPerUnit;
  final String unitLabel;

  const MarginIndicator({super.key, required this.marginPercent, required this.profitPerUnit, this.unitLabel = 'unit'});

  @override
  State<MarginIndicator> createState() => _MarginIndicatorState();
}

class _MarginIndicatorState extends State<MarginIndicator> {
  @override
  void initState() {
    super.initState();
    BusinessSettingsRepository.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BusinessSettings>(
      valueListenable: BusinessSettingsRepository.instance.current,
      builder: (context, settings, _) {
        final rating = rateMargin(widget.marginPercent, settings.healthyMarginPercent);
        final Color fg = switch (rating) {
          MarginRating.healthy => AppColors.success,
          MarginRating.low => AppColors.warning,
          null => AppColors.textSecondary,
        };
        final Color bg = switch (rating) {
          MarginRating.healthy => AppColors.successBg,
          MarginRating.low => AppColors.warningBg,
          null => AppColors.surfaceContainerLow,
        };
        final IconData icon = switch (rating) {
          MarginRating.healthy => Icons.check_circle,
          MarginRating.low => Icons.warning_amber_rounded,
          null => Icons.info_outline_rounded,
        };
        final text = 'Margin ${widget.marginPercent.toStringAsFixed(1)}% '
            '(₱${widget.profitPerUnit.toStringAsFixed(2)} profit/${widget.unitLabel})'
            '${rating == null ? ' • healthy-margin line not set' : ''}';
        return Semantics(
          container: true,
          label: text,
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: AppTextStyles.labelMd.copyWith(color: fg))),
              ],
            ),
          ),
        );
      },
    );
  }
}
