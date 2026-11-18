import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Small "Pending sync" pill for anything saved on this device that the
/// server does not have yet (it disappears once the change has synced).
/// With [failed] it reads "Sync failed" instead (the server refused it; see
/// the sync queue to retry or discard).
class PendingSyncChip extends StatelessWidget {
  const PendingSyncChip({super.key, this.failed = false});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    final color = failed ? AppColors.error : AppColors.warning;
    return Semantics(
      label: failed ? 'Sync failed' : 'Pending sync',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: failed ? AppColors.errorBg : AppColors.warningBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(failed ? Icons.sync_problem_rounded : Icons.sync_rounded, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              failed ? 'Sync failed' : 'Pending sync',
              style: AppTextStyles.labelSm.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
