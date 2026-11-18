import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../widgets/inventory_card.dart';

/// Batches at this branch that still have stock and expire within
/// [AppConstants.expiringSoonDays] days (expired ones included), soonest
/// first. Opened from the "Expiring Soon" stat and from expiry notifications.
class ExpiringSoonScreen extends StatelessWidget {
  const ExpiringSoonScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(
      builder: (context, store) {
        final batches = store.batches
            .where((b) => b.quantity > 0 && b.daysUntilExpiry <= AppConstants.expiringSoonDays)
            .toList()
          ..sort((a, b) => a.daysUntilExpiry.compareTo(b.daysUntilExpiry));
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: const MelaiAppBar(title: 'Expiring Soon', showBack: true),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshInventory,
              child: DataStateView(
                isLoading: store.inventoryState.busy,
                error: store.inventoryState.error,
                isEmpty: batches.isEmpty,
                onRetry: store.refreshInventory,
                emptyIcon: Icons.event_available_rounded,
                emptyTitle: 'Nothing is expiring soon.',
                emptyMessage: 'No batch expires within the next ${AppConstants.expiringSoonDays} days.',
                builder: (context) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Text(
                      'Batches expiring within ${AppConstants.expiringSoonDays} days, soonest first. '
                      'Sell these before newer stock.',
                      style: AppTextStyles.bodySm,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    for (final batch in batches)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InventoryCard.batch(
                          batch: batch,
                          onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryBatchDetails, arguments: batch),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
