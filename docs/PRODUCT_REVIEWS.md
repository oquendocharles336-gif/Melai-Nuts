# Product ratings and reviews

Migration `supabase/migrations/20261119020000_product_reviews.sql` (and
`20261119010000_customer_name_parts.sql` for the reviewer's first name + last initial).
Tests: `supabase/tests/product_reviews_test.sql`, `admin/tests/Feature/ShopReviewsTest.php`,
`test/product_reviews_test.dart`.

| Rule | Where |
|---|---|
| 1-5 stars and an optional comment (≤ 500 characters, words not only emoji). | `product_reviews` CHECKs, `ValidationUtils.validateReviewComment`, `Rules::reviewComment` |
| Only a signed-in customer, only for a product of one of their **completed** orders, one review per product. They edit or delete their own. | RLS on `product_reviews` + `can_review_product()`, unique `(product_id, customer_id)` |
| Everyone reads visible reviews: first name + last initial, stars, comment, date. Nobody reads who wrote it. | `get_product_reviews()`, column grants |
| Average and count of visible reviews (cards and product page). | view `product_rating_stats` |
| Staff / owner hide, show or delete any review (app only: Profile → Product Reviews). Each action is in the staff audit log. | `staff_list_product_reviews()`, `staff_moderate_product_review()` |

Clients: the app's `ProductReviewsRepository` / `ProductReviewsSection` / `StaffReviewsScreen`; the
website's `ShopReviews` / `ReviewController` (`/shop/p/{id}/reviews.json` is loaded by `shop.js`).
