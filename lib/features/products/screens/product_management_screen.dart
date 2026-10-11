import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';

/// Standalone "Product & Pricing Hub" page (kept so the `/products` route
/// still works). The content lives in [ProductManagementBody], which is also
/// embedded as the "Products" tab in the Owner Portal bottom navigation.
class ProductManagementScreen extends StatelessWidget {
  const ProductManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: 'Product & Pricing Hub', showBack: true),
      body: SafeArea(child: ProductManagementBody()),
    );
  }
}

/// "Product & Pricing Hub" content — the Product Management landing view.
/// Matches the prototype's dashboard: catalog/margin stats, category
/// revenue & margin breakdown, recent price adjustments, and quick actions
/// into the rest of the Product Management + Pricing feature. Has no
/// Scaffold of its own so it can be used as a tab body.
class ProductManagementBody extends StatelessWidget {
  const ProductManagementBody({super.key});

  @override
  Widget build(BuildContext context) {
    final activeCount = kProducts.where((p) => p.isActive).length;
    final avgMargin = kProducts.isEmpty
        ? 0.0
        : kProducts.map((p) => p.marginPercent).reduce((a, b) => a + b) / kProducts.length;
    final lowMarginSkus = kProducts.where((p) => p.marginPercent < 50).toList();

    // Group products by category for the revenue/margin breakdown.
    final byCategory = <String, List<Product>>{};
    for (final p in kProducts) {
      byCategory.putIfAbsent(p.categoryId, () => []).add(p);
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Container(
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
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: AppColors.primaryContainer, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.savings_outlined, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Artisanal Peanut Lines & Margin Health', style: AppTextStyles.titleMd),
                        Text('${kBranches.length} branch${kBranches.length == 1 ? '' : 'es'}', style: AppTextStyles.bodySm),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              PrimaryButton(
                label: '+ Add New Product',
                onPressed: () => Navigator.of(context).pushNamed(AppRoutes.productAdd),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Total Active Catalog',
                value: '$activeCount SKUs',
                icon: Icons.inventory_2_outlined,
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.productList),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: 'Average Gross Margin',
                value: '${avgMargin.toStringAsFixed(1)}%',
                icon: Icons.trending_up_rounded,
                valueColor: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Pricing Updates',
                value: 'Today',
                icon: Icons.sync_rounded,
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.productPricing),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: 'Low Margin Alert',
                value: '${lowMarginSkus.length} SKU${lowMarginSkus.length == 1 ? '' : 's'}',
                icon: Icons.warning_amber_rounded,
                valueColor: lowMarginSkus.isEmpty ? AppColors.success : AppColors.error,
                highlight: lowMarginSkus.isNotEmpty,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Category Revenue & Margin Breakdown', style: AppTextStyles.headlineSm),
        const SizedBox(height: AppSpacing.sm),
        for (final entry in byCategory.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _CategoryBreakdownRow(categoryId: entry.key, products: entry.value),
          ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Quick Links', style: AppTextStyles.headlineSm),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _QuickLinkTile(
                icon: Icons.list_alt_rounded,
                label: 'Catalog',
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.productList),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickLinkTile(
                icon: Icons.sell_outlined,
                label: 'Pricing',
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.productPricing),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickLinkTile(
                icon: Icons.leaderboard_outlined,
                label: 'Performance',
                onTap: () => Navigator.of(context).pushNamed(AppRoutes.productPerformance),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;
  final bool highlight;
  final VoidCallback? onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
    this.highlight = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: highlight ? AppColors.errorBg : Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: highlight ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: valueColor ?? AppColors.roleOwner),
            const SizedBox(height: 6),
            Text(value, style: AppTextStyles.headlineSm.copyWith(color: valueColor)),
            Text(label, style: AppTextStyles.bodySm),
          ],
        ),
      ),
    );
  }
}

class _CategoryBreakdownRow extends StatelessWidget {
  final String categoryId;
  final List<Product> products;

  const _CategoryBreakdownRow({required this.categoryId, required this.products});

  @override
  Widget build(BuildContext context) {
    final category = findCategoryById(categoryId);
    final avgPrice = products.isEmpty
        ? 0.0
        : products.map((p) => p.price).reduce((a, b) => a + b) / products.length;
    final avgMargin = products.isEmpty
        ? 0.0
        : products.map((p) => p.marginPercent).reduce((a, b) => a + b) / products.length;

    return Container(
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
              Icon(category.icon, size: 18, color: category.color),
              const SizedBox(width: 8),
              Expanded(child: Text(category.name, style: AppTextStyles.labelLg)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
                child: Text('${products.length} SKUs', style: AppTextStyles.labelSm),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Avg. price ₱${avgPrice.toStringAsFixed(2)}', style: AppTextStyles.bodySm),
              Text('Margin ${avgMargin.toStringAsFixed(1)}%', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (avgMargin / 100).clamp(0, 1),
              minHeight: 6,
              backgroundColor: AppColors.border,
              color: category.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickLinkTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickLinkTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.roleOwner),
            const SizedBox(height: 6),
            Text(label, style: AppTextStyles.labelMd),
          ],
        ),
      ),
    );
  }
}