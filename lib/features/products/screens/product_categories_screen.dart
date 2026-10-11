import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../data/models/product.dart';
import '../../../app/routes.dart';

/// Dedicated "browse by category" screen — a grid of every product
/// category. Tapping a category opens [ProductListScreen] filtered to it.
class ProductCategoriesScreen extends StatelessWidget {
  const ProductCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'All Categories', showBack: true),
      body: SafeArea(
        child: GridView.builder(
          padding: const EdgeInsets.all(AppSpacing.md),
          itemCount: kProductCategories.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
          ),
          itemBuilder: (context, i) {
            final cat = kProductCategories[i];
            final count = productsByCategory(cat.id).length;
            return InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              onTap: () => Navigator.of(context).pushNamed(
                AppRoutes.customerProductList,
                arguments: cat.id,
              ),
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
                    _CategoryAvatar(category: cat),
                    const Spacer(),
                    Text(cat.name, style: AppTextStyles.titleMd),
                    Text('$count items', style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Category "photo": the real staff-uploaded image
/// (`product_categories.image_url`) when one exists, otherwise the on-brand
/// icon/color placeholder — never a fake stock photo.
class _CategoryAvatar extends StatelessWidget {
  final ProductCategory category;

  const _CategoryAvatar({required this.category});

  @override
  Widget build(BuildContext context) {
    final imageUrl = category.imageUrl;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          imageUrl,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: category.color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(category.icon, color: category.color),
    );
  }
}
