import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Selectable pill chip used for category/status filter rows
/// (Product Catalog category tabs, Order History status tabs, etc).
///
/// The ripple is drawn on the chip's own [Material], so it shows on top of
/// the fill. The selected chip also gets a check mark, so the state never
/// relies on colour alone.
class CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: ShapeDecoration(
          shape: shape,
          color: selected ? AppColors.primary : AppColors.ivory,
          shadows: selected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: (selected ? AppColors.onPrimary : AppColors.primary).withValues(alpha: 0.18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: selected
                        ? const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(Icons.check_rounded, size: 16, color: AppColors.onPrimary),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Text(
                    label,
                    style: AppTextStyles.labelLg.copyWith(
                      color: selected ? AppColors.onPrimary : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
