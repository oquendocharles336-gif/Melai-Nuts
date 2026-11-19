import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/product_review.dart';
import '../../../data/repositories/product_reviews_repository.dart';

/// "Ratings & Reviews" on the product page: the average, the count, the list
/// of reviews (first name + last initial, stars, comment, date) and, for a
/// customer who received this product (a completed order), their own review
/// to write, edit or delete. Loading, empty, error and retry states included.
class ProductReviewsSection extends StatefulWidget {
  final String productId;
  final String productName;

  /// Called after the customer's review was saved or deleted (the average changed).
  final VoidCallback? onChanged;

  const ProductReviewsSection({super.key, required this.productId, required this.productName, this.onChanged});

  @override
  State<ProductReviewsSection> createState() => _ProductReviewsSectionState();
}

class _ProductReviewsSectionState extends State<ProductReviewsSection> {
  final _repo = ProductReviewsRepository.instance;

  bool _loading = true;
  Object? _error;
  ProductRatingStats _stats = ProductRatingStats.none;
  List<ProductReview> _reviews = const [];
  MyReviewStatus _mine = MyReviewStatus.guest;
  bool _hasMore = false;
  bool _loadingMore = false;

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
      final signedIn = AuthService.instance.currentFirebaseUser != null;
      final results = await AppErrors.guard(
        () => Future.wait<Object>([
          _repo.fetchStatsFor(widget.productId),
          _repo.fetchReviews(widget.productId),
          if (signedIn) _repo.fetchMyStatus(widget.productId),
        ]),
        scope: ErrorScope.catalog,
        timeout: AppErrors.rpcTimeout,
      );
      if (!mounted) return;
      final reviews = results[1] as List<ProductReview>;
      setState(() {
        _stats = results[0] as ProductRatingStats;
        _reviews = reviews;
        _hasMore = reviews.length >= ProductReviewsRepository.pageSize;
        _mine = signedIn ? results[2] as MyReviewStatus : MyReviewStatus.guest;
        _loading = false;
      });
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'product_reviews_section:load');
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
        () => _repo.fetchReviews(widget.productId, offset: _reviews.length),
        scope: ErrorScope.catalog,
        timeout: AppErrors.rpcTimeout,
      );
      if (!mounted) return;
      setState(() {
        _reviews = [..._reviews, ...more];
        _hasMore = more.length >= ProductReviewsRepository.pageSize;
      });
    } catch (e) {
      if (mounted) _snack(AppErrors.from(e, scope: ErrorScope.catalog).message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppSpacing.radiusLg)),
      ),
      builder: (_) => _ReviewForm(
        productId: widget.productId,
        productName: widget.productName,
        existing: _mine.review,
      ),
    );
    if (saved == true && mounted) {
      _snack(_mine.review == null ? 'Thanks! Your review is posted.' : 'Your review is updated.');
      widget.onChanged?.call();
      await _load();
    }
  }

  Future<void> _delete(ProductReview review) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Delete your review?',
      message: 'Your rating and comment for ${widget.productName} will be removed.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    try {
      await AppErrors.guard(() => _repo.delete(review.id), scope: ErrorScope.catalog);
      if (!mounted) return;
      _snack('Your review was deleted.');
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (mounted) _snack(AppErrors.from(e, scope: ErrorScope.catalog).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.reviews_outlined, size: 18, color: AppColors.darkBrown),
              const SizedBox(width: 8),
              Expanded(child: Text('Ratings & Reviews', style: AppTextStyles.titleMd)),
            ],
          ),
          const SizedBox(height: 10),
          ..._body(),
        ],
      ),
    );
  }

  List<Widget> _body() {
    if (_loading) {
      return const [StateLoadingView(message: 'Loading reviews…', compact: true)];
    }
    if (_error != null) {
      return [StateErrorView(error: _error, onRetry: _load, scope: ErrorScope.catalog, compact: true)];
    }
    final mine = _mine.review;
    final others = _reviews.where((r) => r.id != mine?.id).toList();
    return [
      if (_stats.count > 0) _Summary(stats: _stats) else Text('No reviews yet.', style: AppTextStyles.bodyMd),
      const SizedBox(height: 12),
      if (mine != null) ...[
        Text('Your review', style: AppTextStyles.labelLg),
        const SizedBox(height: 6),
        _ReviewTile(review: mine, highlight: true),
        if (mine.isHidden)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Hidden by Melai Nuts: other customers do not see it.',
                style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: SecondaryButton(label: 'Edit', icon: Icons.edit_outlined, onPressed: _openForm)),
            const SizedBox(width: 8),
            Expanded(
              child: SecondaryButton(label: 'Delete', icon: Icons.delete_outline_rounded, onPressed: () => _delete(mine)),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ] else if (_mine.canReview) ...[
        PrimaryButton(
          label: _stats.count == 0 ? 'Be the first to review' : 'Write a review',
          icon: Icons.rate_review_outlined,
          onPressed: _openForm,
        ),
        const SizedBox(height: 12),
      ] else if (_mine.signedIn) ...[
        Text('You can review this product once an order with it is completed.', style: AppTextStyles.bodySm),
        const SizedBox(height: 12),
      ],
      if (others.isEmpty && mine == null && _stats.count == 0)
        const StateEmptyView(
          icon: Icons.star_outline_rounded,
          title: 'No reviews yet',
          message: 'Customers who received this product can rate it here.',
          compact: true,
        ),
      for (final r in others) ...[
        _ReviewTile(review: r),
        const Divider(height: 20),
      ],
      if (_hasMore)
        Center(
          child: TextButton(
            onPressed: _loadingMore ? null : _loadMore,
            child: Text(_loadingMore ? 'Loading…' : 'Show more reviews'),
          ),
        ),
    ];
  }
}

class _Summary extends StatelessWidget {
  final ProductRatingStats stats;
  const _Summary({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(stats.average.toStringAsFixed(1), style: AppTextStyles.headlineMd),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StarRow(rating: stats.average, size: 18),
            const SizedBox(height: 2),
            Text('${stats.count} ${stats.count == 1 ? 'review' : 'reviews'}', style: AppTextStyles.bodySm),
          ],
        ),
      ],
    );
  }
}

/// Five stars filled up to [rating] (halves rounded to the nearest half star).
class StarRow extends StatelessWidget {
  final double rating;
  final double size;
  const StarRow({super.key, required this.rating, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final halves = (rating * 2).round();
    return Semantics(
      label: '${rating.toStringAsFixed(1)} out of 5 stars',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              halves >= i * 2
                  ? Icons.star_rounded
                  : (halves == i * 2 - 1 ? Icons.star_half_rounded : Icons.star_outline_rounded),
              size: size,
              color: AppColors.warning,
            ),
        ],
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final ProductReview review;
  final bool highlight;
  const _ReviewTile({required this.review, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('MMM d, y').format(review.createdAt);
    return Container(
      width: double.infinity,
      padding: highlight ? const EdgeInsets.all(10) : EdgeInsets.zero,
      decoration: highlight
          ? BoxDecoration(color: AppColors.primaryContainer.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(AppSpacing.radiusSm))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(review.reviewerName, style: AppTextStyles.labelLg)),
              Text(review.wasEdited ? '$date · edited' : date, style: AppTextStyles.bodySm),
            ],
          ),
          const SizedBox(height: 4),
          StarRow(rating: review.rating.toDouble()),
          if (review.comment.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(review.comment, style: AppTextStyles.bodyMd),
          ],
        ],
      ),
    );
  }
}

/// Bottom sheet: 1-5 stars and an optional comment. Saves through
/// [ProductReviewsRepository]; the database re-checks everything.
class _ReviewForm extends StatefulWidget {
  final String productId;
  final String productName;
  final ProductReview? existing;
  const _ReviewForm({required this.productId, required this.productName, this.existing});

  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  final _formKey = GlobalKey<FormState>();
  late final _comment = TextEditingController(text: widget.existing?.comment ?? '');
  late int _rating = widget.existing?.rating ?? 0;
  bool _saving = false;
  String? _ratingError;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _ratingError = _rating < 1 ? 'Choose 1 to 5 stars.' : null);
    final formOk = FormUtils.validateAndFocus(_formKey);
    if (_ratingError != null || !formOk) return;
    final uid = AuthService.instance.currentFirebaseUser?.uid;
    if (uid == null) {
      _snack('Please sign in again to review.');
      return;
    }
    setState(() => _saving = true);
    try {
      final existing = widget.existing;
      await AppErrors.guard(
        () => existing == null
            ? ProductReviewsRepository.instance.create(
                firebaseUid: uid, productId: widget.productId, rating: _rating, comment: _comment.text)
            : ProductReviewsRepository.instance.update(reviewId: existing.id, rating: _rating, comment: _comment.text),
        scope: ErrorScope.catalog,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _snack(AppErrors.from(e, scope: ErrorScope.catalog).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.md,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? 'Review ${widget.productName}' : 'Edit your review',
                  style: AppTextStyles.titleMd),
              const SizedBox(height: 12),
              Text('Your rating', style: AppTextStyles.labelLg),
              Row(
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      tooltip: '$i ${i == 1 ? 'star' : 'stars'}',
                      onPressed: _saving ? null : () => setState(() {
                        _rating = i;
                        _ratingError = null;
                      }),
                      icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                          size: 32, color: AppColors.warning),
                    ),
                ],
              ),
              if (_ratingError != null)
                Text(_ratingError!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
              const SizedBox(height: 8),
              AppTextField(
                label: 'Comment (optional)',
                controller: _comment,
                hint: 'What did you like about it?',
                maxLines: 4,
                maxLength: InputLimits.review,
                textCapitalization: TextCapitalization.sentences,
                liveValidate: true,
                enabled: !_saving,
                validator: ValidationUtils.validateReviewComment,
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: widget.existing == null ? 'Post review' : 'Save changes',
                icon: Icons.check_rounded,
                loading: _saving,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
