<?php

namespace Tests\Feature;

use App\Services\AdminActions;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Live pages: the pulse, the page hash and messages carried by in-page answers. */
class LivePagesTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_the_pulse_reports_a_change_made_in_the_app_and_drops_the_cache(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $first = $this->signedIn($owner)->getJson("/ui/pulse.json")->assertOk()->assertJson(["changed" => false])->json("sig");
        $this->signedIn($owner)->getJson('/ui/pulse.json')->assertJson(['changed' => false, 'sig' => $first]);

        $version = AdminActions::version();
        $this->db->orders[0]['updated_at'] = '2099-01-01T00:00:00+00:00';   // changed in the app, not on the website
        $second = $this->signedIn($owner)->getJson('/ui/pulse.json')->assertJson(['changed' => true])->json('sig');
        $this->assertNotSame($first, $second);
        $this->assertSame($version + 1, AdminActions::version(), 'cached pages are dropped');
        $this->signedIn($owner)->getJson('/ui/pulse.json')->assertJson(['changed' => false, 'sig' => $second]);
    }

    public function test_the_pulse_falls_back_to_the_data_version_when_the_database_cannot_answer(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->db->offline = true;

        $sig = $this->signedIn($owner)->getJson('/ui/pulse.json')->assertOk()->assertJson(['changed' => false])->json('sig');
        AdminActions::bump();
        $this->assertNotSame($sig, $this->signedIn($owner)->getJson('/ui/pulse.json')->json('sig'));
    }

    public function test_a_page_fragment_has_a_stable_hash_and_carries_its_message(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $hash = fn ($html) => preg_match('/data-fragment[^>]*data-hash="([0-9a-f]+)"/', $html, $m) ? $m[1] : null;

        $a = $this->signedIn($owner)->get('/admin/payments', ['X-Melai-Fragment' => '1'])->assertOk()->getContent();
        $b = $this->signedIn($owner)->withSession(['status' => 'Order ORD-1 marked as paid.'])
            ->get('/admin/payments', ['X-Melai-Fragment' => '1'])->assertOk()->getContent();
        $this->assertNotNull($hash($a));
        $this->assertSame($hash($a), $hash($b), 'a one-time message does not count as changed data');
        $this->assertStringContainsString('marked as paid', html_entity_decode((string) (preg_match('/data-flash="([^"]*)"/', $b, $m) ? $m[1] : '')));
    }
}
