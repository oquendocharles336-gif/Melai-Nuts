<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Services\ActivityLogger;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\Request;

/**
 * Product reviews (owner): every customer review of every product, hidden ones included, with the
 * product, customer, rating, comment and date. Filter by product, search, sort, and hide / show /
 * delete an inappropriate one. Reads and writes go through the app's own database functions
 * (admin_list_product_reviews, staff_moderate_product_review) as the signed-in owner, so the
 * database decides who may see and change them; each change is in both activity logs.
 */
class ProductReviewController extends Controller
{
    public const PER_PAGE = 25;

    public const STATUSES = ['all' => 'Visible and hidden', 'visible' => 'Visible only', 'hidden' => 'Hidden only'];

    public const SORTS = ['newest' => 'Newest first', 'oldest' => 'Oldest first', 'rating_high' => 'Highest rating', 'rating_low' => 'Lowest rating'];

    public function __construct(private SupabaseRepository $repo) {}

    public function index(Request $request)
    {
        $f = $this->filters($request);
        $page = max(1, min(1000, (int) $request->query('page', 1)));
        $data = $this->repo->productReviews($f['q'] !== '' ? $f['q'] : null, $f['product'], $f['status'], $f['sort'], self::PER_PAGE, ($page - 1) * self::PER_PAGE);
        $pages = max(1, (int) ceil($data['total'] / self::PER_PAGE));

        return view('admin.reviews.index', $f + [
            'reviews' => $data['rows'], 'total' => $data['total'], 'products' => $data['products'], 'summary' => $data['summary'],
            'page' => min($page, $pages), 'pages' => $pages, 'statuses' => self::STATUSES, 'sorts' => self::SORTS, 'liveData' => true,
        ]);
    }

    public function moderate(Request $request, string $review)
    {
        abort_unless(preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $review) === 1, 404);
        $action = $request->validate(['action' => ['required', 'in:hide,show,delete']])['action'];

        $this->repo->moderateReview($review, $action);
        $done = ['hide' => 'Hid', 'show' => 'Showed again', 'delete' => 'Deleted'][$action];
        ActivityLogger::log('review.'.$action, "$done product review {$review}", $request->user(), ['review_id' => $review]);

        $message = ['hide' => 'Review hidden: customers no longer see it.', 'show' => 'Review visible again.', 'delete' => 'Review deleted.'][$action];

        // Back to the same filtered list (only our own query string, never another site).
        $f = $this->filters($request, true);
        $keep = array_filter(['q' => $f['q'], 'product' => $f['product'], 'status' => $f['status'] !== 'all' ? $f['status'] : null, 'sort' => $f['sort'] !== 'newest' ? $f['sort'] : null]);

        return redirect()->route('admin.reviews.index', $keep)->with('status', $message);
    }

    /** The list filters, from the query string (or the form that posted). */
    private function filters(Request $request, bool $fromInput = false): array
    {
        $get = fn (string $k) => $fromInput ? $request->input($k) : $request->query($k);
        $product = (string) $get('product');
        $status = (string) $get('status');
        $sort = (string) $get('sort');

        return [
            'q' => mb_substr(trim((string) $get('q')), 0, 100),
            'product' => preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $product) === 1 ? $product : null,
            'status' => array_key_exists($status, self::STATUSES) ? $status : 'all',
            'sort' => array_key_exists($sort, self::SORTS) ? $sort : 'newest',
        ];
    }
}
