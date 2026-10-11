import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/order.dart';
import '../../../data/models/refund.dart';
import '../../../data/repositories/refunds_repository.dart';
import 'refund_success_screen.dart';
import 'refund_failed_screen.dart';

/// Real-time, read-only refund status. There is no "advance my own refund"
/// button here — only staff/owner tooling (out of scope for this app) can
/// move a request from Pending to Approved/Processing/Completed. This
/// screen just watches the real row in Supabase and reflects whatever
/// actually happens to it, live.
class RefundProcessingScreen extends StatefulWidget {
  final RefundRequest request;

  const RefundProcessingScreen({super.key, required this.request});

  @override
  State<RefundProcessingScreen> createState() => _RefundProcessingScreenState();
}

class _RefundProcessingScreenState extends State<RefundProcessingScreen> {
  late RefundRequest _request;
  Stream<List<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _stream = RefundsRepository.instance.watchRequest(_request.id);
  }

  Future<void> _refetch() async {
    try {
      final updated = await RefundsRepository.instance.refetch(_request.id);
      if (mounted) setState(() => _request = updated);
    } catch (_) {
      // Keep showing the last known state; the stream will retry.
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        // A change came in over realtime — pull the full row (with its
        // updated status-event history) rather than trusting the partial
        // payload, then render whatever is really there.
        if (snapshot.hasData) {
          final rows = snapshot.data!;
          if (rows.isNotEmpty && rows.first['status'] != _request.status.name) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _refetch());
          }
        }
        return _buildScaffold(context);
      },
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final request = _request;
    final isRejected = request.status == RefundStatus.rejected;
    final isCompleted = request.status == RefundStatus.completed;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Refund ${request.id}', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Order ${request.orderId}', style: AppTextStyles.titleMd, overflow: TextOverflow.ellipsis),
                        Text(
                          '₱${request.amount.toStringAsFixed(0)} • ${request.reason}',
                          style: AppTextStyles.bodySm,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: request.status.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(request.status.label, style: AppTextStyles.labelMd.copyWith(color: request.status.color)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Refund Timeline', style: AppTextStyles.titleMd),
                Text('Live', style: AppTextStyles.labelSm.copyWith(color: AppColors.success)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            for (int i = 0; i < request.timeline.length; i++)
              _TimelineRow(step: request.timeline[i], isLast: i == request.timeline.length - 1),
            if (request.timeline.isEmpty)
              Text('No status updates yet.', style: AppTextStyles.bodyMd.copyWith(color: AppColors.textMuted)),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'A branch staff member reviews every refund request — this page updates automatically the moment they act on it.',
                      style: AppTextStyles.bodySm,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: (isRejected || isCompleted)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: PrimaryButton(
                  label: isRejected ? 'View Rejection Details' : 'View Refund Receipt',
                  icon: isRejected ? Icons.info_outline_rounded : Icons.receipt_long_rounded,
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => isRejected
                          ? RefundFailedScreen(request: request)
                          : RefundSuccessScreen(request: request),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final OrderTimelineStep step;
  final bool isLast;

  const _TimelineRow({required this.step, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final color = step.done ? AppColors.success : (step.current ? AppColors.primary : AppColors.border);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(
                  step.done ? Icons.check : (step.current ? Icons.hourglass_top_rounded : Icons.circle),
                  size: 13,
                  color: Colors.white,
                ),
              ),
              if (!isLast) Expanded(child: Container(width: 2, color: AppColors.border)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(step.label, style: AppTextStyles.labelLg.copyWith(color: step.current ? AppColors.primary : AppColors.textPrimary)),
                  Text(step.description, style: AppTextStyles.bodySm),
                  Text(step.time, style: AppTextStyles.bodySm.copyWith(color: AppColors.textMuted)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
