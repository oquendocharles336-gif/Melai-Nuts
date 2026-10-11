import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../data/views/branch_deliveries.dart';
import '../../../data/models/delivery.dart';

/// Rider's "Assigned Deliveries" list — every active dispatch assigned to
/// the signed-in rider (matched by their real staff name). Tapping a
/// delivery opens its Delivery Details screen, the first step of the rider
/// flow: Assigned Deliveries → Delivery Details → Optimized Route → Start
/// Delivery → GPS Tracking → Next Stop → Update Status → Confirmation →
/// Completed.
class AssignedDeliveriesScreen extends StatelessWidget {
  const AssignedDeliveriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _content(context, store));
  }

  Widget _content(BuildContext context, StaffStore store) {
    if (!store.deliveriesState.loaded && !store.deliveriesState.loading && store.deliveriesState.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.refreshDeliveries());
    }
    final riderName = store.profile?.fullName ?? '';
    final assigned = activeDeliveries.where((d) => d.riderName == riderName).toList();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Assigned Deliveries', showBack: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: store.refreshDeliveries,
          child: assigned.isEmpty
              ? ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: Text('No deliveries assigned right now.', style: AppTextStyles.bodyMd)),
                    ),
                  ],
                )
              : ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: assigned.length,
                separatorBuilder: (context, index) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final delivery = assigned[i];
                  final started = delivery.stops.any((s) => s.status != StopStatus.pending);
                  return _AssignedCard(
                    delivery: delivery,
                    onTap: () => Navigator.of(context).pushNamed(
                      started ? AppRoutes.deliveryActive : AppRoutes.deliveryDetails,
                      arguments: delivery,
                    ),
                  );
                },
              ),
        ),
      ),
    );
  }
}

class _AssignedCard extends StatelessWidget {
  final Delivery delivery;
  final VoidCallback onTap;

  const _AssignedCard({required this.delivery, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nextStop = delivery.stops.where((s) => s.status == StopStatus.pending || s.status == StopStatus.enRoute).toList();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(14),
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
                Expanded(child: Text(delivery.id, style: AppTextStyles.labelLg)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: delivery.status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Text(delivery.status.label, style: AppTextStyles.labelSm.copyWith(color: delivery.status.color)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${delivery.branch} • ${delivery.vehicle}', style: AppTextStyles.bodySm),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _MiniStat(icon: Icons.pin_drop_outlined, label: '${delivery.stops.length} stops')),
                Expanded(child: _MiniStat(icon: Icons.route_outlined, label: '${delivery.totalDistanceKm.toStringAsFixed(1)} km')),
                Expanded(child: _MiniStat(icon: Icons.schedule_outlined, label: '${delivery.totalTimeMinutes} min')),
              ],
            ),
            if (nextStop.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    const Icon(Icons.navigation_rounded, size: 14, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Next: ${nextStop.first.customerName}',
                        style: AppTextStyles.bodySm,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MiniStat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Expanded(child: Text(label, style: AppTextStyles.bodySm, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
