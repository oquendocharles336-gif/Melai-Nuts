/// A customer's rating (1-5) and comment of a product (`public.product_reviews`,
/// migration 20261119020000). Customers see the reviewer as first name + last
/// initial ("Juan D."), never who wrote it.
class ProductReview {
  final String id;
  final String productId;
  final int rating;
  final String comment;
  final String reviewerName;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Written by the signed-in customer.
  final bool isMine;

  /// Hidden by staff (only the author and staff ever see a hidden review).
  final bool isHidden;

  /// Staff list only.
  final String? productName;

  const ProductReview({
    required this.id,
    required this.productId,
    required this.rating,
    required this.comment,
    required this.reviewerName,
    required this.createdAt,
    required this.updatedAt,
    this.isMine = false,
    this.isHidden = false,
    this.productName,
  });

  bool get wasEdited => updatedAt.difference(createdAt).inSeconds > 1;

  static DateTime _date(Object? v) =>
      (v is String ? DateTime.tryParse(v)?.toLocal() : null) ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory ProductReview.fromJson(Map<String, dynamic> j) => ProductReview(
        id: j['id'] as String,
        productId: j['product_id'] as String,
        rating: ((j['rating'] as num?)?.toInt() ?? 0).clamp(1, 5),
        comment: (j['comment'] as String?) ?? '',
        reviewerName: ((j['reviewer_name'] as String?) ?? '').trim().isEmpty
            ? 'Customer'
            : (j['reviewer_name'] as String).trim(),
        createdAt: _date(j['created_at']),
        updatedAt: _date(j['updated_at'] ?? j['created_at']),
        isMine: j['is_mine'] == true,
        isHidden: j['is_hidden'] == true,
        productName: j['product_name'] as String?,
      );
}

/// Average rating and number of visible reviews of one product
/// (`public.product_rating_stats`).
class ProductRatingStats {
  final double average;
  final int count;

  const ProductRatingStats({required this.average, required this.count});

  static const ProductRatingStats none = ProductRatingStats(average: 0, count: 0);

  factory ProductRatingStats.fromJson(Map<String, dynamic> j) => ProductRatingStats(
        average: (j['average_rating'] as num?)?.toDouble() ?? 0,
        count: (j['review_count'] as num?)?.toInt() ?? 0,
      );
}

/// What the review form needs for the signed-in customer
/// (`my_product_review_status`): whether they may review (a completed order
/// with this product) and their own review, if any.
class MyReviewStatus {
  final bool signedIn;
  final bool canReview;
  final ProductReview? review;

  const MyReviewStatus({required this.signedIn, required this.canReview, this.review});

  static const MyReviewStatus guest = MyReviewStatus(signedIn: false, canReview: false);

  factory MyReviewStatus.fromJson(Map<String, dynamic> j) => MyReviewStatus(
        signedIn: j['signed_in'] == true,
        canReview: j['can_review'] == true,
        review: j['review'] is Map ? ProductReview.fromJson(Map<String, dynamic>.from(j['review'] as Map)) : null,
      );
}
