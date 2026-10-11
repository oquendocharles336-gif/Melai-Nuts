import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/products_repository.dart';
import 'product_list_screen.dart';

/// Dedicated customer category browser. Categories and product counts are
/// fetched from Supabase; inactive categories are excluded by the query.
class ProductCategoriesScreen extends StatefulWidget {
  const ProductCategoriesScreen({super.key});

  @override
  State<ProductCategoriesScreen> createState() =>
      _ProductCategoriesScreenState();
}

class _ProductCategoriesScreenState extends State<ProductCategoriesScreen> {
  late Future<List<ProductCategory>> _future;

  @override
  void initState() {
    super.initState();
    _future = ProductsRepository.instance.fetchActiveCategoriesWithCounts();
  }

  void _retry() {
    setState(() {
      _future = ProductsRepository.instance.fetchActiveCategoriesWithCounts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'All Categories', showBack: true),
      body: SafeArea(
        child: FutureBuilder<List<ProductCategory>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        'We could not load product categories. Please try again.',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodyMd,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ),
                ),
              );
            }

            final categories = snapshot.data ?? const <ProductCategory>[];
            if (categories.isEmpty) {
              return Center(
                child: Text(
                  'No active product categories are available.',
                  style: AppTextStyles.bodyMd,
                ),
              );
            }

            return GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: categories.length,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.3,
              ),
              itemBuilder: (context, i) {
                final category = categories[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ProductListScreen(categoryId: category.id),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CategoryAvatar(category: category),
                        const Spacer(),
                        Text(category.name, style: AppTextStyles.titleMd),
                        Text(
                          '${category.productCount} item${category.productCount == 1 ? '' : 's'}',
                          style: AppTextStyles.bodySm,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// Uses the real category image URL when staff has uploaded one.
/// Otherwise it uses the category icon stored in Supabase.
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
