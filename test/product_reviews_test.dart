import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/validation_utils.dart';
import 'package:melai_nuts/data/models/product_review.dart';

void main() {
  group('product reviews (migration 20261119020000)', () {
    test('a review row from get_product_reviews', () {
      final r = ProductReview.fromJson({
        'id': 'r1',
        'product_id': 'p1',
        'rating': 4,
        'comment': 'Crunchy',
        'reviewer_name': 'Ana D.',
        'created_at': '2026-11-19T02:00:00Z',
        'updated_at': '2026-11-19T02:00:00Z',
        'is_mine': true,
      });
      expect(r.rating, 4);
      expect(r.reviewerName, 'Ana D.');
      expect(r.isMine, isTrue);
      expect(r.wasEdited, isFalse);
    });

    test('a missing name is shown as Customer; the rating stays within 1-5', () {
      final r = ProductReview.fromJson({'id': 'r', 'product_id': 'p', 'rating': 9, 'reviewer_name': ' '});
      expect(r.reviewerName, 'Customer');
      expect(r.rating, 5);
    });

    test('stats and status', () {
      final s = ProductRatingStats.fromJson({'average_rating': 3.5, 'review_count': 2});
      expect(s.average, 3.5);
      expect(s.count, 2);
      final status = MyReviewStatus.fromJson({'signed_in': true, 'can_review': true, 'review': null});
      expect(status.canReview, isTrue);
      expect(status.review, isNull);
    });

    test('the comment uses the same rules as the website and the database', () {
      expect(ValidationUtils.validateReviewComment(''), isNull);
      expect(ValidationUtils.validateReviewComment('Great nuts!'), isNull);
      expect(ValidationUtils.validateReviewComment('🔥🔥🔥'), isNotNull);
      expect(ValidationUtils.validateReviewComment('a' * (InputLimits.review + 1)), isNotNull);
    });
  });
}
