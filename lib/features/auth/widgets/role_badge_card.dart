import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/user_role.dart';

/// A tappable role badge used in the login screen's "Quick Demo Role
/// Switcher". Highlights when selected.
class RoleBadgeCard extends StatelessWidget {
  final UserRole role;
  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const RoleBadgeCard({
    super.key,
    required this.role,
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? role.color.withValues(alpha: 0.10) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? role.color : AppColors.border,
            width: selected ? 1.6 : 1,
          ),
          boxShadow: selected ? null : AppShadows.sm,
        ),
        child: Row(
          children: [
            Icon(role.icon, size: 20, color: role.color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: AppTextStyles.labelLg,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: AppTextStyles.bodySm,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
