<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Support\ListTools;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Request;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Search, pagination and CSV on Orders, Payments, Refunds and Activity logs. */
class ListPagesTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function manyOrders(int $n): void
    {
        $this->db->orders = []; // only this test's orders
        for ($i = 1; $i <= $n; $i++) {
            $this->db->addOrder(sprintf('ORD-%03d', $i), 'b-cal', 100 + $i);
            $this->db->orders[$i - 1]['created_at'] = now()->subMinutes($n - $i + 1)->toIso8601String(); // ORD-001 oldest
        }
        $this->db->orders[0]['payment']['reference_number'] = 'GC-REF-777';
        $this->db->orders[1]['customer_name'] = '=cmd|calc';
    }

    public function test_list_tools(): void
    {
        $rows = [['t' => 'Garlic Peanuts Calamba'], ['t' => 'Cashew Los Baños'], ['t' => 'garlic cashew']];
        $this->assertCount(2, ListTools::search($rows, 'GARLIC', fn ($r) => $r['t']));
        $this->assertCount(1, ListTools::search($rows, 'garlic cashew', fn ($r) => $r['t']), 'every word must match');
        $this->assertCount(3, ListTools::search($rows, '  ', fn ($r) => $r['t']));
        $p = ListTools::paginate(range(1, 30), Request::create('/x', 'GET', ['page' => 9, 'q' => 'a']), 25);
        $this->assertSame(2, $p->currentPage(), 'a page past the end shows the last page');
        $this->assertSame([26, 27, 28, 29, 30], $p->items());
        $this->assertStringContainsString('q=a', $p->url(1));
        $this->assertSame("'=1+2", ListTools::cell('=1+2'));
        $this->assertSame('-5', ListTools::cell(-5));
    }

    public function test_payments_search_pages_and_csv(): void
    {
        $this->useFakeSupabase();
        $this->manyOrders(30);
        $owner = $this->linkedLogin('uid-owner');

        $page = $this->signedIn($owner)->get('/admin/payments')->assertOk()->assertSee('1–10 of 30', false)->assertSee('data-pager', false);
        $this->assertCount(10, $page->viewData('orders')->items());
        $this->signedIn($owner)->get('/admin/payments?page=3')->assertOk()->assertSee('ORD-001');
        $this->assertSame(1, $this->signedIn($owner)->get('/admin/payments?q=GC-REF-777')->assertOk()->viewData('orders')->total());

        // "Rows" per page: ?per_page= or the size saved in this browser (cookie), never an odd value.
        $this->assertCount(25, $this->signedIn($owner)->get('/admin/payments?per_page=25')->viewData('orders')->items());
        $this->assertCount(10, $this->signedIn($owner)->get('/admin/payments?per_page=7')->viewData('orders')->items());
        $this->signedIn($owner)->get('/admin/payments?page=2&fresh=1')->assertDontSee('fresh=1', false);
        $this->assertCount(30, $this->signedIn($owner)->withUnencryptedCookie('melai_per_page', '50')->get('/admin/payments')->viewData('orders')->items());

        $csv = $this->signedIn($owner)->get('/admin/payments/export?q=ORD-00')->assertOk()->streamedContent();
        $this->assertSame(9, substr_count($csv, "\nORD-00"), 'all matches, not only one page');
        $this->assertStringContainsString("'=cmd|calc", $csv, 'formula-safe');
    }

    public function test_refunds_search_and_csv(): void
    {
        $this->useFakeSupabase();
        $this->manyOrders(3);
        $this->db->orders[2]['refund'] = ['id' => 'RF-9', 'status' => 'pending', 'amount' => 50, 'reason' => 'Crushed pack', 'notes' => '', 'completed_at' => null];
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/admin/refunds?q=crushed')->assertOk()->assertSee('RF-9');
        $this->signedIn($owner)->get('/admin/refunds?q=nothing-like-this')->assertOk()->assertSee('No refund requests match');
        $csv = $this->signedIn($owner)->get('/admin/refunds/export')->assertOk()->streamedContent();
        $this->assertStringContainsString('refund,order,placed_at', $csv);
        $this->assertStringContainsString('RF-9,ORD-003', $csv);
    }

    public function test_orders_csv_follows_the_screen_filters(): void
    {
        $this->useFakeSupabase();
        $this->manyOrders(4);
        $owner = $this->linkedLogin('uid-owner');
        $csv = $this->signedIn($owner)->get('/orders/export?status=all&q=ORD-002')->assertOk()->streamedContent();
        $this->assertStringContainsString('order,placed_at,branch,channel', $csv);
        $this->assertSame(1, substr_count($csv, "\nORD-"));
        $this->assertStringContainsString('in-store', $csv);
    }

    public function test_activity_log_search_pages_and_csv(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        for ($i = 0; $i < 30; $i++) {
            ActivityLog::create(['user_id' => $owner->id, 'action' => 'test.action', 'description' => "Entry $i", 'ip_address' => '10.0.0.1']);
        }
        ActivityLog::create(['user_id' => $owner->id, 'action' => 'refund.approved', 'description' => 'Approved refund RF-1', 'ip_address' => '10.0.0.2']);

        $page = $this->signedIn($owner)->get('/admin/activity-logs')->assertOk();
        $this->assertTrue($page->viewData('logs')->hasPages());
        $this->signedIn($owner)->get('/admin/activity-logs?q=refund')->assertOk()->assertSee('Approved refund RF-1')->assertDontSee('Entry 5');
        $this->signedIn($owner)->get('/admin/activity-logs?q=100%25')->assertOk(); // LIKE wildcards are escaped

        $csv = $this->signedIn($owner)->get('/admin/activity-logs/export?source=website&q=test.action')->assertOk()->streamedContent();
        $this->assertSame(30, substr_count($csv, 'test.action'));
    }

    public function test_staff_cannot_export_admin_lists(): void
    {
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');
        foreach (['/admin/payments/export', '/admin/refunds/export', '/admin/activity-logs/export'] as $url) {
            $this->signedIn($staff)->get($url)->assertForbidden();
        }
    }
}
