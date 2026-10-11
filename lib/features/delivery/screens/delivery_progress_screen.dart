import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/delivery.dart';

/// Overall progress across every stop in the active delivery — a
/// checklist/timeline view of what's delivered, delayed, or still pending.
class DeliveryProgressScreen extends StatelessWidget {
  final Delivery delivery;

  const DeliveryProgressScreen({super.key, required this.delivery});

  @override
  Widget build(BuildContext context) {
    final progress = delivery.stops.isEmpty ? 0.0 : delivery.deliveredCount / delivery.stops.length;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Delivery Progress', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(delivery.id, style: AppTextStyles.titleMd),
                      Text('${delivery.deliveredCount}/${delivery.stops.length} delivered', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: progress, minHeight: 10, backgroundColor: AppColors.border, color: AppColors.success),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Stop Timeline', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < delivery.stops.length; i++)
              _TimelineTile(
                index: i + 1,
                stop: delivery.stops[i],
                isLast: i == delivery.stops.length - 1,
              ),
            const SizedBox(height: AppSpacing.lg),
            if (delivery.isComplete)
              PrimaryButton(
                label: 'View Completion Summary',
                icon: Icons.celebration_outlined,
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryCompleted, arguments: delivery),
              )
            else
              PrimaryButton(
                label: 'Go to Next Stop',
                icon: Icons.arrow_forward_rounded,
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.deliveryNextStop, arguments: delivery),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  final int index;
  final DeliveryStop stop;
  final bool isLast;

  const _TimelineTile({required this.index, required this.stop, required this.isLast});

  IconData get _icon {
    switch (stop.status) {
      case StopStatus.delivered:
        return Icons.check_circle;
      case StopStatus.delayed:
        return Icons.schedule_rounded;
      case StopStatus.skipped:
        return Icons.cancel_rounded;
      case StopStatus.failed:
        return Icons.report_gmailerrorred_rounded;
      case StopStatus.enRoute:
        return Icons.local_shipping_rounded;
      case StopStatus.pending:
        return Icons.radio_button_unchecked;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: stop.status.color.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(_icon, size: 15, color: stop.status.color),
              ),
              if (!isLast) Expanded(child: Container(width: 2, color: AppColors.border)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('$index. ${stop.customerName}', style: AppTextStyles.labelLg)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: stop.status.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                          child: Text(stop.status.label, style: AppTextStyles.labelSm.copyWith(color: stop.status.color)),
                        ),
                      ],
                    ),
                    Text('ETA ${stop.eta}', style: AppTextStyles.bodySm),
                    if (stop.issueReason != null) Text('Note: ${stop.issueReason}', style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
