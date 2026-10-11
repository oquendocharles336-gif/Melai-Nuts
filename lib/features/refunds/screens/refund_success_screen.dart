import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/refund.dart';

class RefundSuccessScreen extends StatelessWidget {
  final RefundRequest request;

  const RefundSuccessScreen({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
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
                decoration: const BoxDecoration(color: AppColors.successBg, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: AppColors.success, size: 46),
              ),
              const SizedBox(height: 16),
              Text('Refund Completed', style: AppTextStyles.headlineMd),
              const SizedBox(height: 6),
              Text(
                '₱${request.amount.toStringAsFixed(0)} was credited back via ${request.paymentMethod}.',
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
                  children: [
                    _Row('Refund ID', request.id),
                    _Row('Order Reference', request.orderId),
                    _Row('Refunded To', request.paymentMethod),
                    _Row('Amount', '₱${request.amount.toStringAsFixed(0)}'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Done',
                icon: Icons.check_rounded,
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodySm),
          Expanded(child: Text(value, style: AppTextStyles.labelLg, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}