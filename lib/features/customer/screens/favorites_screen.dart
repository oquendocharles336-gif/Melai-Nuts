import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/repositories/favorites_repository.dart';
import '../widgets/favorite_button.dart';
import '../widgets/product_card.dart';
import 'product_details_screen.dart';

/// The customer's saved products, shown from the live catalogue of the
/// selected branch (prices and stock are today's).
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _repo = FavoritesRepository.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    await _repo.load();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Favourites', showBack: true),
      body: ListenableBuilder(
        listenable: _repo,
        builder: (context, _) {
          final products = kProducts.where((p) => _repo.contains(p.id)).toList();
          final elsewhere = _repo.ids.length - products.length;
          return DataStateView(
            isLoading: _loading && !_repo.isLoaded,
            error: _repo.isLoaded ? null : _repo.lastError,
            isEmpty: products.isEmpty,
            onRetry: _reload,
            emptyIcon: Icons.favorite_border_rounded,
            emptyTitle: _repo.ids.isEmpty ? 'No favourites yet' : 'None of your favourites are sold at this branch',
            emptyMessage: _repo.ids.isEmpty ? 'Tap the heart on a product to save it here.' : 'Switch branch to see them.',
            builder: (context) => RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  for (final p in products)
                    Card(
                      child: ListTile(
                        title: Text(p.name, style: AppTextStyles.labelLg),
                        subtitle: Text('₱${p.price.toStringAsFixed(0)} · ${CustomerStockChip.of(p).label}', style: AppTextStyles.bodySm),
                        trailing: FavoriteButton(productId: p.id, productName: p.name),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ProductDetailsScreen(product: p)),
                        ),
                      ),
                    ),
                  if (elsewhere > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$elsewhere more not sold at this branch.', style: AppTextStyles.bodySm),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
