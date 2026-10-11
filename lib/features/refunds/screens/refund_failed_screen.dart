import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/refund.dart';

class RefundFailedScreen extends StatelessWidget {
  final RefundRequest request;

  const RefundFailedScreen({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final rejectionStep = request.timeline.isNotEmpty ? request.timeline.last : null;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(color: AppColors.errorBg, shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, color: AppColors.error, size: 46),
              ),
              const SizedBox(height: 16),
              Text('Refund Request Rejected', style: AppTextStyles.headlineMd, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'Request ${request.id} for Order ${request.orderId} was not approved.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              Container(
                width: double.infinity,
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
                    Text('Reason for Rejection', style: AppTextStyles.bodySm),
                    Text(rejectionStep?.description ?? 'Not eligible under refund policy.', style: AppTextStyles.labelLg),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Back to Orders',
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
