import 'package:flutter/material.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/loyalty.dart';

class LoyaltyHistoryScreen extends StatelessWidget {
  const LoyaltyHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CustomerDataStore.instance,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final store = CustomerDataStore.instance;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Points History'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: DataStateView(
        isLoading: store.isLoading,
        error: store.error,
        isEmpty: CustomerDataStore.instance.loyaltyTransactions.isEmpty,
        onRetry: () => store.retry(),
        emptyIcon: Icons.history_rounded,
        emptyTitle: 'No history yet.',
        emptyMessage: 'Your points activity will appear here.',
        loadingMessage: 'Loading your points history...',
        builder: (context) => RefreshIndicator(
          onRefresh: () => store.refresh(),
          child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),

              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: CustomerDataStore.instance.loyaltyTransactions.length,
              separatorBuilder: (context, index) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final tx = CustomerDataStore.instance.loyaltyTransactions[index];
                final isEarn = tx.type == LoyaltyTransactionType.earn;

                return Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Material(type: MaterialType.transparency, child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isEarn ? AppColors.successBg : AppColors.errorBg,
                      child: Icon(
                        isEarn ? Icons.add : Icons.remove,
                        color: isEarn ? AppColors.success : AppColors.error,
                      ),
                    ),
                    title: Text(tx.description, style: AppTextStyles.titleMd),
                    subtitle: Text(
                      '${tx.date.day}/${tx.date.month}/${tx.date.year} • ${tx.date.hour}:${tx.date.minute}'
                      '${tx.isRefundReversal ? ' • reversed because the order was refunded' : ''}',
                      style: AppTextStyles.bodySm,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${isEarn ? '+' : '-'}${tx.points}',
                          style: AppTextStyles.labelLg.copyWith(
                            color: isEarn ? AppColors.success : AppColors.error,
                          ),
                        ),
                        Text(
                          'Points',
                          style: AppTextStyles.labelSm,
                        ),
                      ],
                    ),
                    onTap: () => Navigator.pushNamed(
                      context,
                      '/customer/loyalty/transaction',
                      arguments: tx,
                    ),
                  )),
                );
              },
            ),
        ),
      ),
    );
  }
}
