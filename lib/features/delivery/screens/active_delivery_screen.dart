import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';

/// The rider's "control center" for a delivery that's already in
/// progress — current status, next stop preview, and quick access into
/// GPS Tracking, Next Stop, Route Details, and overall Progress.
class ActiveDeliveryScreen extends StatelessWidget {
  final Delivery delivery;

  const ActiveDeliveryScreen({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final nextStop = delivery.stops.cast<DeliveryStop?>().firstWhere(
          (s) => s!.status == StopStatus.pending || s.status == StopStatus.enRoute,
      orElse: () => null,
    );
    final progress = delivery.stops.isEmpty ? 0.0 : delivery.deliveredCount / delivery.stops.length;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ACTIVE DISPATCH', style: AppTextStyles.labelSm),
            Text(delivery.id, style: AppTextStyles.titleMd),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            // The run on the map: customer pins in stop order, next stop highlighted.
            RunMapCard(delivery: delivery, height: 220),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_shipping_rounded, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(delivery.vehicle, style: AppTextStyles.labelLg),
                            Text('Rider: ${delivery.riderName}', style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: delivery.status.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          delivery.status.label,
                          style: AppTextStyles.labelSm.copyWith(color: delivery.status.color),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Overall Progress', style: AppTextStyles.labelMd),
                      Text(
                        '${delivery.deliveredCount}/${delivery.stops.length} Delivered',
                        style: AppTextStyles.labelMd.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 10,
                      backgroundColor: AppColors.border,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (nextStop != null) ...[
              Text('Up Next', style: AppTextStyles.headlineSm),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                          child: const Icon(Icons.person_pin_circle_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(nextStop.customerName, style: AppTextStyles.titleMd),
                              Text(nextStop.address, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(child: _ActionTile(icon: Icons.navigation_rounded, label: 'GPS Track', onTap: () => Navigator.of(context).pushNamed(AppRoutes.gpsTracking, arguments: delivery))),
                        const SizedBox(width: 10),
                        Expanded(child: _ActionTile(icon: Icons.checklist_rounded, label: 'Handle Stop', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryNextStop, arguments: delivery))),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Quick Links', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            _LinkRow(icon: Icons.list_alt_rounded, label: 'View Full Progress', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryProgress, arguments: delivery)),
            _LinkRow(icon: Icons.map_outlined, label: 'Detailed Route Info', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryRouteDetails, arguments: delivery)),
            _LinkRow(icon: Icons.inventory_2_outlined, label: 'Loading Manifest', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryManifest, arguments: delivery)),
            _LinkRow(icon: Icons.info_outline_rounded, label: 'General Details', onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDetails, arguments: delivery)),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.primary.withValues(alpha: 0.1))),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(height: 4),
            Text(label, style: AppTextStyles.labelMd.copyWith(color: AppColors.primary)),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LinkRow({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        tileColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.border)),
        leading: Icon(icon, color: AppColors.textSecondary),
        title: Text(label, style: AppTextStyles.labelLg),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
