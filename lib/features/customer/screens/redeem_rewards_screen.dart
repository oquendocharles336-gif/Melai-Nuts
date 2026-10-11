import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../widgets/reward_card.dart';
import '../widgets/reward_redeem_action.dart';

class RedeemRewardsScreen extends StatelessWidget {
  const RedeemRewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CustomerDataStore.instance,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final store = CustomerDataStore.instance;
    final userPoints = CustomerDataStore.instance.pointsBalance;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Redeem Rewards',
        showBack: true,
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Text(
                  '$userPoints pts',
                  style: AppTextStyles.labelMd.copyWith(color: AppColors.primary),
                ),
              ),
            ),
          ),
        ],
      ),
      body: DataStateView(
        isLoading: store.isLoading,
        error: store.error,
        isEmpty: CustomerDataStore.instance.rewards.isEmpty,
        onRetry: () => store.retry(),
        emptyIcon: Icons.card_giftcard_rounded,
        emptyTitle: 'No rewards yet.',
        emptyMessage: 'Keep earning points to see available rewards.',
        loadingMessage: 'Loading rewards...',
        builder: (context) => RefreshIndicator(
          onRefresh: () => store.refresh(),
          child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),

              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: CustomerDataStore.instance.rewards.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final reward = CustomerDataStore.instance.rewards[index];
                return RewardCard(
                  reward: reward,
                  canRedeem: userPoints >= reward.pointsRequired,
                  onRedeem: () => redeemRewardAndNavigate(context, reward),
                );
              },
            ),
        ),
      ),
    );
  }
}
