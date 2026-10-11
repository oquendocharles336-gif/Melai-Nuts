import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/delivery.dart';
import '../widgets/run_map_card.dart';
import '../../../core/utils/app_error.dart';

/// Packing manifest for a dispatch — every stop's order items (from the
/// database) grouped for the loading/packing crew. "Copy manifest" puts the
/// list on the clipboard so it can be pasted or printed elsewhere; the app has
/// no PDF export and no packing status in the database, so neither is faked.
class DeliveryManifestScreen extends StatelessWidget {
  final Delivery delivery;

  const DeliveryManifestScreen({super.key, required this.delivery});

  String _asText() {
    final b = StringBuffer()
      ..writeln('Delivery ${delivery.id} — ${delivery.branch}')
      ..writeln('Vehicle: ${delivery.vehicle} • Rider: ${delivery.riderName}')
      ..writeln('${delivery.stops.length} stops • ${delivery.totalItems} item lines')
      ..writeln();
    for (var i = 0; i < delivery.stops.length; i++) {
      final s = delivery.stops[i];
      b.writeln('${i + 1}. ${s.customerName} (${s.orderId})');
      b.writeln('   ${s.address}');
      for (final item in s.items) {
        b.writeln('   - $item');
      }
    }
    return b.toString();
  }

  Future<void> _copy(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: _asText()));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Manifest copied to the clipboard.')));
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'delivery_manifest_screen:42');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not copy the manifest on this device.')));
    }
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(
        title: 'Manifest • ${delivery.id}',
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy manifest',
            onPressed: () => _copy(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Row(
                children: [
                  Expanded(child: _Summary(label: 'Branch', value: delivery.branch)),
                  Expanded(child: _Summary(label: 'Vehicle', value: delivery.vehicle)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
              child: Row(
                children: [
                  Expanded(child: _Summary(label: 'Total Stops', value: '${delivery.stops.length}')),
                  Expanded(child: _Summary(label: 'Item Lines', value: '${delivery.totalItems}')),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // Where each stop goes (customer pins, numbered in loading order).
            RunMapCard(delivery: delivery, height: 220),
            const SizedBox(height: AppSpacing.lg),
            Text('Packing List by Stop', style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < delivery.stops.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border), boxShadow: AppShadows.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: AppColors.primaryContainer, shape: BoxShape.circle),
                            child: Text('${i + 1}', style: AppTextStyles.labelSm.copyWith(color: AppColors.primaryDark)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(delivery.stops[i].customerName, style: AppTextStyles.labelLg)),
                          Text(delivery.stops[i].orderId, style: AppTextStyles.bodySm),
                        ],
                      ),
                      const Divider(height: 16),
                      for (final item in delivery.stops[i].items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.circle, size: 6, color: AppColors.textSecondary),
                              const SizedBox(width: 8),
                              Expanded(child: Text(item, style: AppTextStyles.bodyMd)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (delivery.stops.isEmpty)
              Text('This run has no stops.', style: AppTextStyles.bodyMd),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(
              label: 'Copy Manifest',
              icon: Icons.copy_all_outlined,
              onPressed: () => _copy(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final String label;
  final String value;

  const _Summary({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.bodySm),
        Text(value, style: AppTextStyles.titleMd),
      ],
    );
  }
}
