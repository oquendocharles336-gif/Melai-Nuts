import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A soft rounded callout box used for policy notices / hints
/// (e.g. "Security Policy", "A 6-digit code will be sent").
class InfoBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? background;
  final Color? foreground;
  final String? title;

  const InfoBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.background,
    this.foreground,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? AppColors.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background ?? AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: AppTextStyles.labelLg.copyWith(color: fg),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  text,
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
