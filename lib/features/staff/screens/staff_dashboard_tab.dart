import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/luxe.dart';
import '../../../core/widgets/motion.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/staff_models.dart';
import '../widgets/staff_avatar.dart';
import 'cash_drawer_screen.dart';

/// Staff dashboard. Every number is computed by the database for the branch
/// being worked in and refreshes when orders, stock, transfers or refunds
/// change.
class StaffDashboardTab extends StatelessWidget {
  /// Switches the portal's bottom navigation (1 = Register, 2 = Orders,
  /// 3 = Inventory, 4 = Profile).
  final ValueChanged<int> onOpenTab;

  const StaffDashboardTab({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final d = store.dashboard;
        return RefreshIndicator(
          onRefresh: store.refreshAll,
          child: DataStateView(
            isLoading: store.dashboardState.busy,
            error: store.dashboardState.error,
            isEmpty: d == null,
            onRetry: store.refreshDashboard,
            emptyIcon: Icons.dashboard_outlined,
            emptyTitle: 'No dashboard data yet.',
            builder: (context) => _content(context, store, d!),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, StaffStore store, StaffDashboard d) {
    final profile = store.profile!;
    final nav = Navigator.of(context);
    final canRefund = profile.isOwner || profile.canReviewRefunds;

    final alerts = <_Stat>[
      _Stat('Low stock', '${d.lowStockCount}', Icons.warning_amber_rounded, _amber,
          () => nav.pushNamed(AppRoutes.inventoryLowStock), attention: d.lowStockCount > 0),
      _Stat('Out of stock', '${d.outOfStockCount}', Icons.remove_shopping_cart_outlined, AppColors.error,
          () => nav.pushNamed(AppRoutes.inventoryLowStock), attention: d.outOfStockCount > 0),
      _Stat('Expiring within 15 days', '${d.expiringSoonCount}', Icons.schedule_rounded, _amber,
          () => nav.pushNamed(AppRoutes.inventoryFefo), attention: d.expiringSoonCount > 0),
      _Stat('Transfers to approve', '${d.transfersAwaitingApproval}', Icons.outbox_rounded, AppColors.roleStaff,
          () => nav.pushNamed(AppRoutes.inventoryTransfers), attention: d.transfersAwaitingApproval > 0),
      _Stat('Transfers arriving', '${d.transfersAwaitingReceipt}', Icons.move_to_inbox_rounded, AppColors.roleStaff,
          () => nav.pushNamed(AppRoutes.inventoryTransfers), attention: d.transfersAwaitingReceipt > 0),
      if (d.pendingRefunds != null)
        _Stat(
            'Open refund requests (not deducted yet)',
            d.pendingRefundAmount == null ? '${d.pendingRefunds}' : '${d.pendingRefunds} • ${peso(d.pendingRefundAmount!)}',
            Icons.assignment_return_outlined,
            AppColors.error,
            () => nav.pushNamed(AppRoutes.staffRefunds),
            attention: (d.pendingRefunds ?? 0) > 0),
    ];
    final needsAttention = alerts.where((a) => a.attention).length;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
      children: [
        FadeSlideIn(
          child: _Hero(
            profile: profile,
            dashboard: d,
            onAvatarTap: () => onOpenTab(4),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FadeSlideIn(
          delay: const Duration(milliseconds: 80),
          child: Row(
            children: [
              _QuickAction('Register', Icons.point_of_sale_rounded, AppColors.roleStaff, () => onOpenTab(1)),
              _QuickAction('Orders', Icons.receipt_long_rounded, AppColors.primary, () => onOpenTab(2)),
              _QuickAction('Stock', Icons.inventory_2_rounded, AppColors.success, () => onOpenTab(3)),
              _QuickAction(
                'Deliveries',
                Icons.local_shipping_rounded,
                const Color(0xFF2563EB),
                () => nav.pushNamed(AppRoutes.deliveryDashboard),
              ),
              _QuickAction(
                'Drawer',
                Icons.account_balance_wallet_rounded,
                const Color(0xFF7C3AED),
                () => nav.push(MaterialPageRoute(builder: (_) => const CashDrawerScreen())),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FadeSlideIn(
          delay: const Duration(milliseconds: 140),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle("Today's orders"),
              const SizedBox(height: AppSpacing.sm),
              _OrderFlow(dashboard: d, onTap: () => onOpenTab(2)),
              const SizedBox(height: 10),
              _grid([
                _Stat("Today's orders", '${d.ordersToday}', Icons.receipt_long_rounded, AppColors.primary, () => onOpenTab(2)),
                _Stat('Cancelled today', '${d.cancelledToday}', Icons.cancel_outlined, AppColors.error, () => onOpenTab(2)),
                _Stat('Refunds today', d.refundsToday == null ? '—' : '${pesoOrDash(d.refundsToday)} (${d.refundCountToday ?? 0})',
                    Icons.undo_rounded, AppColors.error, canRefund ? () => nav.pushNamed(AppRoutes.staffRefunds) : () => onOpenTab(2)),
                _Stat('Refund rate today', rateOrDash(d.refundRateToday), Icons.percent_rounded, _amber, () => onOpenTab(2)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FadeSlideIn(
          delay: const Duration(milliseconds: 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: _SectionTitle('Needs your attention')),
                  _AttentionChip(count: needsAttention),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _grid(alerts),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FadeSlideIn(
          delay: const Duration(milliseconds: 260),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle('Your branch'),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadows.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoLine(Icons.storefront_rounded, d.branch.name),
                    if (d.branch.address.isNotEmpty) _InfoLine(Icons.place_rounded, d.branch.address),
                    if ((d.branch.contactPhone ?? '').isNotEmpty) _InfoLine(Icons.call_rounded, d.branch.contactPhone!),
                    if ((d.branch.operatingHours ?? '').isNotEmpty) _InfoLine(Icons.access_time_rounded, d.branch.operatingHours!),
                    _InfoLine(
                      Icons.local_shipping_rounded,
                      [
                        if (d.branch.supportsPickup) 'Pickup',
                        if (d.branch.supportsDelivery) 'Delivery',
                      ].join(' • ').ifEmpty('No pickup or delivery'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _grid(List<_Stat> stats) {
    return Builder(
      builder: (context) => GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          // Grows with the phone's text size, so two-line labels always fit.
          mainAxisExtent: MediaQuery.textScalerOf(context).scale(100),
        ),
        children: [for (final s in stats) _StatCard(stat: s)],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

const _amber = Color(0xFFD97706);

String _greeting(DateTime now) {
  if (now.hour < 12) return 'Good morning';
  if (now.hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/// Greeting, branch status and today's net sales, on the orange hero.
class _Hero extends StatelessWidget {
  final StaffProfile profile;
  final StaffDashboard dashboard;
  final VoidCallback onAvatarTap;

  const _Hero({required this.profile, required this.dashboard, required this.onAvatarTap});

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    final firstName = profile.fullName.trim().isEmpty ? '' : profile.fullName.trim().split(RegExp(r'\s+')).first;
    final net = d.netSalesToday;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.heroGradientStart, AppColors.heroGradientEnd],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        boxShadow: AppShadows.md,
      ),
      child: CustomPaint(
        painter: LatticePainter(color: Colors.white.withValues(alpha: 0.07)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onAvatarTap,
                    child: StaffAvatar(profile: profile, size: 52),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          firstName.isEmpty ? _greeting(DateTime.now()) : '${_greeting(DateTime.now())}, $firstName!',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.headlineSm.copyWith(color: Colors.white),
                        ),
                        Text(
                          '${profile.roleLabel} • ${d.branch.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodySm.copyWith(color: AppColors.gold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: d.branch.isActive ? AppColors.successBg : AppColors.errorBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: d.branch.isActive ? AppColors.success : AppColors.error),
                        const SizedBox(width: 5),
                        Text(
                          d.branch.isActive ? 'Open' : 'Closed',
                          style: AppTextStyles.labelSm.copyWith(color: d.branch.isActive ? AppColors.success : AppColors.error),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                "TODAY'S NET SALES",
                style: AppTextStyles.labelSm.copyWith(color: AppColors.gold, letterSpacing: 1.6),
              ),
              const SizedBox(height: 2),
              // net_sales_today missing = older server: unknown ("—"), never its old gross figure.
              if (net == null)
                Text(pesoOrDash(net), style: AppTextStyles.display.copyWith(color: Colors.white))
              else
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: net),
                  duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(peso(value), style: AppTextStyles.display.copyWith(color: Colors.white)),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                net == null
                    ? 'Net sales need the latest database update • updated ${friendlyTime(d.generatedAt)}'
                    : 'Gross ${pesoOrDash(d.grossSalesToday)} − discounts ${pesoOrDash(d.discountsToday)} − refunds '
                        '${pesoOrDash(d.refundsToday)} • updated ${friendlyTime(d.generatedAt)}',
                style: AppTextStyles.bodySm.copyWith(color: AppColors.gold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickAction(this.label, this.icon, this.color, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.32), blurRadius: 12, offset: const Offset(0, 5))],
                  ),
                  child: Icon(icon, color: Colors.white, size: 25),
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, style: AppTextStyles.labelMd.copyWith(color: AppColors.textPrimary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Orders moving through the branch: pending, preparing, ready, completed.
class _OrderFlow extends StatelessWidget {
  final StaffDashboard dashboard;
  final VoidCallback onTap;

  const _OrderFlow({required this.dashboard, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    final steps = [
      ('Pending', d.pendingOrders, Icons.hourglass_top_rounded, _amber),
      ('Preparing', d.preparingOrders, Icons.soup_kitchen_rounded, AppColors.primary),
      ('Ready / out', d.readyOrders, Icons.delivery_dining_rounded, const Color(0xFF2563EB)),
      ('Completed', d.completedToday, Icons.check_circle_rounded, AppColors.success),
    ];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              Expanded(
                child: Column(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(color: steps[i].$4.withValues(alpha: 0.13), shape: BoxShape.circle),
                      child: Icon(steps[i].$3, color: steps[i].$4, size: 22),
                    ),
                    const SizedBox(height: 6),
                    Text('${steps[i].$2}', style: AppTextStyles.headlineSm),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(steps[i].$1, style: AppTextStyles.bodySm),
                    ),
                  ],
                ),
              ),
              if (i < steps.length - 1)
                const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.outlineButton),
            ],
          ],
        ),
      ),
    );
  }
}

class _AttentionChip extends StatelessWidget {
  final int count;

  const _AttentionChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final clear = count == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: clear ? AppColors.successBg : AppColors.warningBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        clear ? 'All clear' : '$count to check',
        style: AppTextStyles.labelSm.copyWith(color: clear ? AppColors.success : AppColors.warning),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(text, style: AppTextStyles.headlineSm);
}

class _Stat {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// This number is asking for someone to look at it.
  final bool attention;

  const _Stat(this.label, this.value, this.icon, this.color, this.onTap, {this.attention = false});
}

class _StatCard extends StatelessWidget {
  final _Stat stat;

  const _StatCard({required this.stat});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppSpacing.radiusMd);
    return Pressable(
      onTap: stat.onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: stat.attention ? Color.alphaBlend(stat.color.withValues(alpha: 0.07), Colors.white) : Colors.white,
          borderRadius: radius,
          border: Border.all(color: stat.attention ? stat.color.withValues(alpha: 0.45) : AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: stat.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                  child: Icon(stat.icon, color: stat.color, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(stat.value, style: AppTextStyles.headlineSm),
                  ),
                ),
              ],
            ),
            Text(stat.label, style: AppTextStyles.bodySm, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.roleStaff),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppTextStyles.bodyMd)),
        ],
      ),
    );
  }
}
