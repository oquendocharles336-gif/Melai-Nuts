import 'package:flutter/material.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/refund.dart';
import 'refund_processing_screen.dart';
import 'refund_success_screen.dart';
import 'refund_failed_screen.dart';

class RefundHistoryScreen extends StatelessWidget {
  const RefundHistoryScreen({super.key});

  void _open(BuildContext context, RefundRequest request) {
    Widget screen;
    switch (request.status) {
      case RefundStatus.completed:
        screen = RefundSuccessScreen(request: request);
        break;
      case RefundStatus.rejected:
        screen = RefundFailedScreen(request: request);
        break;
      default:
        screen = RefundProcessingScreen(request: request);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

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
      appBar: const MelaiAppBar(title: 'Refund History', showBack: true),
      body: SafeArea(
        child: DataStateView(
          isLoading: store.isLoading,
          error: store.error,
          isEmpty: CustomerDataStore.instance.refunds.isEmpty,
          onRetry: () => store.retry(),
          errorScope: ErrorScope.refund,
          emptyIcon: Icons.assignment_return_outlined,
          emptyTitle: 'No refund requests yet.',
          emptyMessage: 'Refund requests you submit for your orders will appear here.',
          loadingMessage: 'Loading refund requests...',
          builder: (context) => RefreshIndicator(
            onRefresh: () => store.refresh(),
            child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          itemCount: CustomerDataStore.instance.refunds.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final r = CustomerDataStore.instance.refunds[i];
            return InkWell(
              onTap: () => _open(context, r),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(r.id, style: AppTextStyles.titleMd, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: r.status.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(r.status.label, style: AppTextStyles.labelSm.copyWith(color: r.status.color)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('Order ${r.orderId} • ${r.itemCount} item(s)', style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(r.reason, style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDate(r.requestedDate), style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted)),
                        Text('₱${r.amount.toStringAsFixed(0)}', style: AppTextStyles.labelLg.copyWith(color: AppColors.primary)),
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
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}