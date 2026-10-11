import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';

/// Ways to add stock to the branch. Both options are real: a new batch is
/// saved to the branch inventory, and a transfer is a request to another
/// branch that only changes stock when that branch ships and this one receives.
class AddInventoryScreen extends StatelessWidget {
  const AddInventoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Add Inventory', showBack: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text('Choose how you want to add stock to this branch.', style: AppTextStyles.bodyMd),
            const SizedBox(height: AppSpacing.lg),
            _OptionCard(
              icon: Icons.add_box_outlined,
              title: 'Receive a New Batch',
              subtitle: 'Log freshly received stock with its batch code and expiry date.',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryReceive),
            ),
            const SizedBox(height: 12),
            _OptionCard(
              icon: Icons.sync_alt_rounded,
              title: 'Transfer from Another Branch',
              subtitle: 'Request stock from another branch and receive it when it arrives.',
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.inventoryTransfers),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _OptionCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.surfaceContainerLow, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.roleStaff),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLg),
                  Text(subtitle, style: AppTextStyles.bodySm),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
