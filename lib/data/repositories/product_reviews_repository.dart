import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/product_review.dart';

/// Product ratings and reviews (migration 20261119020000).
///
/// Reading is open to everyone. Writing goes straight to `product_reviews`
/// under row-level security: the database accepts a review only from the
/// signed-in customer, once per product, and only for a product of one of
/// their COMPLETED orders (the order is picked by the server). Staff and owners
/// moderate through `staff_moderate_product_review`.
class ProductReviewsRepository {
  ProductReviewsRepository._();
  static final ProductReviewsRepository instance = ProductReviewsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  static const int pageSize = 20;

  /// Average rating and count per product id. Products without reviews are
  /// not in the map.
  Future<Map<String, ProductRatingStats>> fetchStats(List<String> productIds) async {
    if (productIds.isEmpty) return const {};
    final raw = await _client
        .from('product_rating_stats')
        .select('product_id,average_rating,review_count')
        .inFilter('product_id', productIds)
        .timeout(AppErrors.queryTimeout);
    return {
      for (final row in List<Map<String, dynamic>>.from(raw))
        row['product_id'] as String: ProductRatingStats.fromJson(row),
    };
  }

  Future<ProductRatingStats> fetchStatsFor(String productId) async =>
      (await fetchStats([productId]))[productId] ?? ProductRatingStats.none;

  /// Visible reviews of [productId], newest first.
  Future<List<ProductReview>> fetchReviews(String productId, {int offset = 0, int limit = pageSize}) async {
    final raw = await _client
        .rpc('get_product_reviews', params: {'p_product_id': productId, 'p_limit': limit, 'p_offset': offset})
        .timeout(AppErrors.rpcTimeout);
    return [
      for (final row in (raw as List? ?? const []))
        ProductReview.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  /// May the signed-in customer review [productId], and their own review.
  Future<MyReviewStatus> fetchMyStatus(String productId) async {
    final raw = await _client
        .rpc('my_product_review_status', params: {'p_product_id': productId})
        .timeout(AppErrors.rpcTimeout);
    return raw is Map ? MyReviewStatus.fromJson(Map<String, dynamic>.from(raw)) : MyReviewStatus.guest;
  }

  Future<void> create({
    required String firebaseUid,
    required String productId,
    required int rating,
    required String comment,
  }) async {
    await _client
        .from('product_reviews')
        .insert({
          'product_id': productId,
          'customer_id': firebaseUid,
          'rating': rating,
          'comment': comment.trim(),
        })
        .select('id')
        .single()
        .timeout(AppErrors.queryTimeout);
  }

  Future<void> update({required String reviewId, required int rating, required String comment}) async {
    await _client
        .from('product_reviews')
        .update({'rating': rating, 'comment': comment.trim()})
        .eq('id', reviewId)
        .select('id')
        .single()
        .timeout(AppErrors.queryTimeout);
  }

  Future<void> delete(String reviewId) async {
    await _client.from('product_reviews').delete().eq('id', reviewId).timeout(AppErrors.queryTimeout);
  }

  // --- Staff / owner ----------------------------------------------------------------------

  /// Every review (hidden ones too), newest first, optionally of one product.
  Future<List<ProductReview>> staffList({String? productId, int offset = 0, int limit = 50}) async {
    final raw = await _client.rpc('staff_list_product_reviews', params: {
      'p_product_id': productId,
      'p_include_hidden': true,
      'p_limit': limit,
      'p_offset': offset,
    }).timeout(AppErrors.rpcTimeout);
    return [
      for (final row in (raw as List? ?? const []))
        ProductReview.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  /// [action]: 'hide', 'show' or 'delete'. Recorded in the staff audit log.
  Future<void> staffModerate(String reviewId, String action) async {
    await _client
        .rpc('staff_moderate_product_review', params: {'p_review_id': reviewId, 'p_action': action})
        .timeout(AppErrors.rpcTimeout);
  }
}
