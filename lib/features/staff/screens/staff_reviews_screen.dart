import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/product_review.dart';
import '../../../data/repositories/product_reviews_repository.dart';
import '../../customer/widgets/product_reviews_section.dart' show StarRow;

/// Staff / owner: every product review (hidden ones too), newest first, with
/// Hide / Show and Delete for inappropriate ones. Each action is written to the
/// staff audit log by the database (staff_moderate_product_review).
class StaffReviewsScreen extends StatefulWidget {
  const StaffReviewsScreen({super.key});

  @override
  State<StaffReviewsScreen> createState() => _StaffReviewsScreenState();
}

class _StaffReviewsScreenState extends State<StaffReviewsScreen> {
  static const int _page = 50;
  final _repo = ProductReviewsRepository.instance;

  List<ProductReview> _reviews = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await AppErrors.guard(() => _repo.staffList(limit: _page), timeout: AppErrors.rpcTimeout);
      if (!mounted) return;
      setState(() {
        _reviews = list;
        _hasMore = list.length >= _page;
        _loading = false;
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_reviews_screen:load');
      if (!mounted) return;
      setState(() {
        _error = caughtError;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more = await AppErrors.guard(
        () => _repo.staffList(offset: _reviews.length, limit: _page),
        timeout: AppErrors.rpcTimeout,
      );
      if (!mounted) return;
      setState(() {
        _reviews = [..._reviews, ...more];
        _hasMore = more.length >= _page;
      });
    } catch (e) {
      if (mounted) _snack(AppErrors.from(e).message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _moderate(ProductReview review, String action) async {
    if (action == 'delete') {
      final ok = await ConfirmDialog.show(
        context,
        title: 'Delete this review?',
        message: 'The review by ${review.reviewerName} on ${review.productName ?? 'this product'} is removed for good.',
        confirmLabel: 'Delete',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(review.id));
    try {
      await AppErrors.guard(() => _repo.staffModerate(review.id, action), timeout: AppErrors.rpcTimeout);
      if (!mounted) return;
      setState(() {
        if (action == 'delete') {
          _reviews = _reviews.where((r) => r.id != review.id).toList();
        } else {
          _reviews = [
            for (final r in _reviews)
              r.id == review.id
                  ? ProductReview(
                      id: r.id,
                      productId: r.productId,
                      rating: r.rating,
                      comment: r.comment,
                      reviewerName: r.reviewerName,
                      createdAt: r.createdAt,
                      updatedAt: r.updatedAt,
                      isHidden: action == 'hide',
                      productName: r.productName,
                    )
                  : r,
          ];
        }
      });
      _snack(switch (action) {
        'hide' => 'Review hidden from customers.',
        'show' => 'Review visible again.',
        _ => 'Review deleted.',
      });
    } catch (e) {
      if (mounted) _snack(AppErrors.from(e).message);
    } finally {
      if (mounted) setState(() => _busy.remove(review.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Product Reviews', showBack: true),
      body: SafeArea(
        child: DataStateView(
          isLoading: _loading,
          error: _error,
          isEmpty: _reviews.isEmpty,
          onRetry: _load,
          emptyIcon: Icons.reviews_outlined,
          emptyTitle: 'No reviews yet',
          emptyMessage: 'Customer reviews of your products appear here.',
          loadingMessage: 'Loading reviews…',
          builder: (context) => RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: _reviews.length + (_hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, i) {
                if (i == _reviews.length) {
                  return Center(
                    child: TextButton(
                      onPressed: _loadingMore ? null : _loadMore,
                      child: Text(_loadingMore ? 'Loading…' : 'Show more'),
                    ),
                  );
                }
                final r = _reviews[i];
                final busy = _busy.contains(r.id);
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: r.isHidden ? AppColors.warningBg : AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.productName ?? 'Product', style: AppTextStyles.labelLg),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          StarRow(rating: r.rating.toDouble()),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${r.reviewerName} · ${DateFormat('MMM d, y').format(r.createdAt)}',
                              style: AppTextStyles.bodySm,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (r.comment.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(r.comment, style: AppTextStyles.bodyMd),
                      ],
                      if (r.isHidden) ...[
                        const SizedBox(height: 6),
                        Text('Hidden from customers', style: AppTextStyles.labelSm.copyWith(color: AppColors.warning)),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: busy ? null : () => _moderate(r, r.isHidden ? 'show' : 'hide'),
                            icon: Icon(r.isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                            label: Text(r.isHidden ? 'Show' : 'Hide'),
                          ),
                          TextButton.icon(
                            onPressed: busy ? null : () => _moderate(r, 'delete'),
                            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.error),
                            label: Text('Delete', style: AppTextStyles.labelMd.copyWith(color: AppColors.error)),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
