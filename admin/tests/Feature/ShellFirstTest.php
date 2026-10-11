<?php

namespace Tests\Feature;

use App\Models\User;
use App\Support\SupabaseTimer;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Heavy pages: instant shell for browsers running our JS, page fragments for in-page navigation. */
class ShellFirstTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function admin(): User
    {
        return User::factory()->create(['role' => 'admin', 'has_access' => true]);
    }

    public function test_without_the_js_cookie_the_full_page_is_rendered_as_before(): void
    {
        $this->actingAs($this->admin())->get('/dashboard')->assertOk()->assertSee('Sales per branch')->assertDontSee('data-shell', false);
    }

    public function test_with_the_js_cookie_heavy_pages_answer_with_a_shell_and_no_database_call(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        foreach (['/dashboard' => 'Overview', '/orders' => 'Orders', '/s/inventory' => 'Stock', '/s/reports' => 'Reports'] as $url => $title) {
            $r = $this->signedIn($owner)->withUnencryptedCookie('melai_js', '1')->get($url)->assertOk()
                ->assertSee('data-shell', false)->assertSee($title)->assertDontSee('Sales per branch')->assertHeader('Cache-Control', 'no-store, private');
            $this->assertSame(0, SupabaseTimer::$calls, "$url shell made a database call");
            $this->assertStringContainsString('data-app-shell', $r->getContent());
        }
        // Other pages are unchanged.
        $this->signedIn($owner)->withUnencryptedCookie('melai_js', '1')->get('/settings')->assertOk()->assertDontSee('data-shell', false);
        // ?full=1 and JSON never get the shell.
        $this->signedIn($owner)->withUnencryptedCookie('melai_js', '1')->get('/dashboard?full=1')->assertOk()->assertDontSee('data-shell', false);
    }

    public function test_guests_and_staff_without_access_never_reach_the_shell(): void
    {
        $this->withUnencryptedCookie('melai_js', '1')->get('/dashboard')->assertRedirect(route('login'));
        $this->actingAs(User::factory()->create(['has_access' => false]))->withUnencryptedCookie('melai_js', '1')->get('/orders')->assertRedirect(route('waiting'));
        $this->actingAs(User::factory()->create(['role' => 'staff', 'has_access' => true]))->withUnencryptedCookie('melai_js', '1')
            ->get('/dashboard')->assertOk()->assertDontSee(route('admin.users.index'));
    }

    public function test_a_fragment_is_only_the_page_content_and_is_never_cached(): void
    {
        $r = $this->actingAs($this->admin())->withHeader('X-Melai-Fragment', '1')->withUnencryptedCookie('melai_js', '1')->get('/dashboard')->assertOk()
            ->assertSee('data-fragment', false)->assertSee('data-nav="overview"', false)->assertSee('Sales per branch')
            ->assertHeader('Cache-Control', 'no-store, private');
        $html = $r->getContent();
        $this->assertStringNotContainsString('<html', $html);
        $this->assertStringNotContainsString('data-app-shell', $html, 'no sidebar');
        $this->assertStringNotContainsString('<script', $html, 'fragments carry no scripts');
        foreach (['/orders', '/settings', '/help'] as $url) {
            $this->actingAs($this->admin())->withHeader('X-Melai-Fragment', '1')->get($url)->assertOk()->assertSee('data-fragment', false);
        }
    }

    public function test_after_a_form_message_the_full_page_is_shown_so_the_message_is_not_lost(): void
    {
        $this->actingAs($this->admin())->withUnencryptedCookie('melai_js', '1')->withSession(['status' => 'Saved.'])
            ->get('/dashboard')->assertOk()->assertDontSee('data-shell', false)->assertSee('Saved.');
    }
}
