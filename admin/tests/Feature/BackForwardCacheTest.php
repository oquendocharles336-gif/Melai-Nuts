<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Routing\Route as LaravelRoute;
use Illuminate\Support\Facades\Route;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Back/Forward showed admin pages without their stylesheets: the in-page navigation fetches the
 * content-only form of a page from the SAME URL, and the browser kept that answer as its copy of the
 * URL. Every page must now mark the content-only answer "never store" and say the URL has two forms.
 * (The real-browser Back/Forward check over every sidebar page is in the pull request notes.)
 */
class BackForwardCacheTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    /** Admin pages a person opens (GET, no route parameters, not a download or JSON endpoint). */
    private function pages(): array
    {
        return collect(Route::getRoutes()->getRoutes())
            ->filter(fn (LaravelRoute $r) => in_array('GET', $r->methods(), true)
                && in_array('auth', $r->gatherMiddleware(), true)
                && ! str_contains($r->uri(), '{')
                && ! preg_match('/export|\.json$|logout|image/', $r->uri()))
            ->map(fn (LaravelRoute $r) => '/'.ltrim($r->uri(), '/'))
            ->values()->all();
    }

    public function test_the_content_only_answer_of_every_admin_page_is_never_stored(): void
    {
        $this->useFakeSupabase();
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $login = $this->linkedLogin($owner);
        $pages = $this->pages();
        $this->assertContains('/help', $pages);
        $this->assertContains('/settings', $pages);
        $this->assertGreaterThan(15, count($pages));

        foreach ($pages as $uri) {
            $fragment = $this->signedIn($login)->withHeaders(['X-Melai-Fragment' => '1'])->get($uri);
            $this->assertStringContainsString('no-store', (string) $fragment->headers->get('Cache-Control'), "$uri fragment must not be stored");
            $this->assertContains('X-Melai-Fragment', $fragment->getVary(), "$uri fragment must say the URL has two forms");

            $this->flushHeaders();   // withHeaders() sticks to later requests
            $full = $this->signedIn($login)->get($uri);
            $this->assertContains('X-Melai-Fragment', $full->getVary(), "$uri page must say the URL has two forms");
        }
    }

    public function test_a_fragment_answer_has_no_page_layout_and_the_full_page_has_its_stylesheets(): void
    {
        $this->useFakeSupabase();
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $login = $this->linkedLogin($owner);

        $this->signedIn($login)->withHeaders(['X-Melai-Fragment' => '1'])->get('/help')
            ->assertOk()->assertDontSee('<head>', false)->assertSee('data-fragment', false);
        $this->flushHeaders();
        $this->signedIn($login)->get('/help')->assertOk()->assertSee('<head>', false);
    }
}
