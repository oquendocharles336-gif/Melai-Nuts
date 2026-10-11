import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/loyalty.dart';
import '../widgets/loyalty_points_card.dart';
import '../widgets/reward_card.dart';
import '../widgets/reward_redeem_action.dart';

/// "Golden Kernel Club" — the customer loyalty home. Matches the
/// prototype's Customer Loyalty Dashboard: profile row, membership card,
/// RFID tap banner, a 2x2 points ledger, available rewards, and recent
/// point activity.
class LoyaltyDashboardScreen extends StatelessWidget {
  const LoyaltyDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CustomerDataStore.instance,
      builder: (context, _) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final store = CustomerDataStore.instance;
    final availablePoints = CustomerDataStore.instance.pointsBalance;
    final lifetimeEarned = CustomerDataStore.instance.loyaltyTransactions
        .where((t) => t.type == LoyaltyTransactionType.earn)
        .fold<int>(0, (sum, t) => sum + t.points);
    // Points taken back by refunds are not points the customer spent.
    final pointsSpent = CustomerDataStore.instance.loyaltyTransactions
        .where((t) => t.type == LoyaltyTransactionType.redeem && !t.isRefundReversal)
        .fold<int>(0, (sum, t) => sum + t.points);
    final pointsReversed = CustomerDataStore.instance.loyaltyTransactions
        .where((t) => t.isRefundReversal)
        .fold<int>(0, (sum, t) => sum + t.points);
    final claimableRewards = CustomerDataStore.instance.rewards.where((r) => r.pointsRequired <= availablePoints).toList();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Golden Kernel Club',
        showBack: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, size: 14, color: AppColors.primaryDark),
                    const SizedBox(width: 4),
                    Text(
                      '$lifetimeEarned pts',
                      style: AppTextStyles.labelMd.copyWith(color: AppColors.primaryDark),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        // loading / error (+ retry) until the rewards data has loaded; after
        // that the sections below show their own real empty messages.
        child: DataStateView(
          isLoading: store.isLoading,
          error: store.error,
          isEmpty: !store.hasLoaded,
          onRetry: () => store.retry(),
          emptyIcon: Icons.workspace_premium_outlined,
          emptyTitle: 'Rewards unavailable',
          emptyMessage: 'Sign in to see your points and rewards.',
          loadingMessage: 'Loading your rewards...',
          builder: (context) => RefreshIndicator(
          onRefresh: () => store.refresh(),
          child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primaryContainer,
                    child: Icon(Icons.person, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Customer Account', style: AppTextStyles.titleMd),
                          ],
                        ),
                        Text('No branch linked', style: AppTextStyles.bodySm),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('New Member', style: AppTextStyles.labelSm.copyWith(color: AppColors.textMuted)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            LoyaltyPointsCard(
              points: availablePoints,
              status: 'Kernel Member',
            ),
            const SizedBox(height: AppSpacing.md),
            InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              onTap: () => Navigator.pushNamed(context, '/customer/loyalty/rfid-tap'),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.outlineVariant, style: BorderStyle.solid),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                      child: const Icon(Icons.contactless_rounded, color: AppColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Tap RFID Card at Store Counter', style: AppTextStyles.labelLg.copyWith(color: AppColors.primaryDark)),
                          Text(
                            'Tap your card at the counter of any Melai Nuts branch',
                            style: AppTextStyles.bodySm,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Loyalty Ledger', style: AppTextStyles.headlineSm),
                Text('Updated Just Now', style: AppTextStyles.bodySm),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.7,
              children: [
                _LedgerTile(
                  label: 'AVAILABLE BALANCE',
                  value: '$availablePoints pts',
                  footer: 'Start earning points',
                  icon: Icons.savings_outlined,
                ),
                _LedgerTile(
                  label: 'LIFETIME EARNED',
                  value: '+$lifetimeEarned pts',
                  footer: 'Earn points to level up',
                  icon: Icons.workspace_premium_outlined,
                ),
                _LedgerTile(
                  label: 'POINTS SPENT',
                  value: '$pointsSpent pts',
                  footer: pointsReversed > 0 ? '$pointsReversed pts reversed by refunds' : 'Vouchers will appear here',
                  icon: Icons.shopping_bag_outlined,
                ),
                _LedgerTile(
                  label: 'ACTIVE PERKS',
                  value: '0 ready',
                  footer: 'Earn points to unlock',
                  icon: Icons.local_offer_outlined,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Available Rewards', style: AppTextStyles.headlineSm),
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/customer/loyalty/redeem'),
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (claimableRewards.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No rewards available yet.', style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted)),
              )
            else
              for (final reward in claimableRewards.take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: RewardCard(
                    reward: reward,
                    canRedeem: reward.pointsRequired <= availablePoints,
                    onRedeem: () => redeemRewardAndNavigate(context, reward),
                  ),
                ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Recent Point Activity', style: AppTextStyles.headlineSm),
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/customer/loyalty/history'),
                  child: const Text('Full History'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: CustomerDataStore.instance.loyaltyTransactions.isEmpty
                  ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(child: Text('No activity yet.', style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted))),
              )
                  : Material(type: MaterialType.transparency, child: Column(
                children: [
                  for (final tx in CustomerDataStore.instance.loyaltyTransactions.take(3))
                    _ActivityRow(tx: tx, isLast: tx == CustomerDataStore.instance.loyaltyTransactions.take(3).last),
                ],
              )),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

class _LedgerTile extends StatelessWidget {
  final String label;
  final String value;
  final String footer;
  final IconData icon;

  const _LedgerTile({
    required this.label,
    required this.value,
    required this.footer,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(child: Text(label, style: AppTextStyles.labelSm)),
            ],
          ),
          const Spacer(),
          Text(value, style: AppTextStyles.headlineSm.copyWith(color: AppColors.darkBrown)),
          Text(footer, style: AppTextStyles.bodySm),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final LoyaltyPointTransaction tx;
  final bool isLast;

  const _ActivityRow({required this.tx, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isEarn = tx.type == LoyaltyTransactionType.earn;
    return Column(
      children: [
        ListTile(
          onTap: () => Navigator.pushNamed(context, '/customer/loyalty/transaction', arguments: tx),
          leading: CircleAvatar(
            backgroundColor: isEarn ? AppColors.successBg : AppColors.errorBg,
            child: Icon(
              isEarn ? Icons.add_rounded : Icons.remove_rounded,
              color: isEarn ? AppColors.success : AppColors.error,
            ),
          ),
          title: Text(tx.description, style: AppTextStyles.labelLg),
          subtitle: Text(
            '${tx.date.day}/${tx.date.month}/${tx.date.year}',
            style: AppTextStyles.bodySm,
          ),
          trailing: Text(
            '${isEarn ? '+' : '-'}${tx.points}',
            style: AppTextStyles.labelLg.copyWith(color: isEarn ? AppColors.success : AppColors.error),
          ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}