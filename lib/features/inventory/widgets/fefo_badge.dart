import 'package:flutter/material.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/inventory_batch.dart';

/// Small colored pill showing a [FefoPriority] tier (HIGH/MEDIUM/LOW).
class FefoBadge extends StatelessWidget {
  final FefoPriority priority;
  final bool showDot;

  const FefoBadge({super.key, required this.priority, this.showDot = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: priority.background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: priority.color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Text(priority.label, style: AppTextStyles.labelSm.copyWith(color: priority.color)),
        ],
      ),
    );
  }
}
