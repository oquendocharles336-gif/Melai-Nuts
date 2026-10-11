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

/// Past deliveries (completed/cancelled), with a status filter and tap
/// through to full details.
class DeliveryHistoryScreen extends StatefulWidget {
  const DeliveryHistoryScreen({super.key});

  @override
  State<DeliveryHistoryScreen> createState() => _DeliveryHistoryScreenState();
}

enum _Filter { all, completed, cancelled }

class _DeliveryHistoryScreenState extends State<DeliveryHistoryScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _content(context, store));
  }

  Widget _content(BuildContext context, StaffStore store) {
    if (!store.deliveriesState.loaded && !store.deliveriesState.loading && store.deliveriesState.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => store.refreshDeliveries());
    }
    var deliveries = pastDeliveries;
    switch (_filter) {
      case _Filter.completed:
        deliveries = deliveries.where((d) => d.status == DeliveryStatus.completed).toList();
        break;
      case _Filter.cancelled:
        deliveries = deliveries.where((d) => d.status == DeliveryStatus.cancelled).toList();
        break;
      case _Filter.all:
        break;
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Delivery History', showBack: true),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SegmentedButton<_Filter>(
                segments: [
                  ButtonSegment(value: _Filter.all, label: Text('All (${pastDeliveries.length})')),
                  ButtonSegment(value: _Filter.completed, label: Text('Completed (${pastDeliveries.where((d) => d.status == DeliveryStatus.completed).length})')),
                  ButtonSegment(value: _Filter.cancelled, label: Text('Cancelled (${pastDeliveries.where((d) => d.status == DeliveryStatus.cancelled).length})')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: store.refreshDeliveries,
                child: store.deliveriesState.busy
                  ? ListView(children: const [Padding(padding: EdgeInsets.symmetric(vertical: 48), child: Center(child: CircularProgressIndicator()))])
                  : deliveries.isEmpty
                  ? ListView(children: [Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Center(child: Text('No deliveries match this filter.', style: AppTextStyles.bodyMd)))])
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                      itemCount: deliveries.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final delivery = deliveries[i];
                        return InkWell(
                          onTap: () => Navigator.of(context).pushNamed(AppRoutes.deliveryDetails, arguments: delivery),
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
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: delivery.status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                                      child: Text(delivery.status.label, style: AppTextStyles.labelSm.copyWith(color: delivery.status.color)),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${delivery.branch} • ${_formatDate(delivery.createdAt)}',
                                  style: AppTextStyles.bodySm,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.pin_drop_outlined, size: 14, color: AppColors.textSecondary),
                                    const SizedBox(width: 4),
                                    Text('${delivery.stops.length} stops', style: AppTextStyles.bodySm),
                                    const SizedBox(width: 12),
                                    Icon(Icons.route_outlined, size: 14, color: AppColors.textSecondary),
                                    const SizedBox(width: 4),
                                    Text('${delivery.totalDistanceKm.toStringAsFixed(1)} km', style: AppTextStyles.bodySm),
                                    const Spacer(),
                                    Text(delivery.riderName, style: AppTextStyles.bodySm),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
