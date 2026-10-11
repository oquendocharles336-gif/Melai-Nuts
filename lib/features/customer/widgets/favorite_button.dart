import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/repositories/favorites_repository.dart';

/// Heart toggle for one product (48dp target, screen-reader label).
class FavoriteButton extends StatelessWidget {
  final String productId;
  final String productName;
  final FavoritesRepository? repository;

  const FavoriteButton({super.key, required this.productId, required this.productName, this.repository});

  @override
  Widget build(BuildContext context) {
    final repo = repository ?? FavoritesRepository.instance;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final on = repo.contains(productId);
        return IconButton(
          tooltip: on ? 'Remove $productName from favourites' : 'Add $productName to favourites',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: Icon(on ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: on ? AppColors.error : AppColors.textSecondary),
          onPressed: () async {
            final ok = await repo.toggle(productId);
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(repo.lastError?.message ?? 'Could not update favourites.')));
            }
          },
        );
      },
    );
  }
}
