<?php

namespace Tests\Unit;

use App\Support\BlockedWords;
use Tests\TestCase;

/**
 * The website's copy of the blocked-words check (App\Support\BlockedWords) against the shared list
 * and test cases in moderation/ (the JavaScript, SQL and Dart copies run the same cases).
 */
class BlockedWordsTest extends TestCase
{
    private function cases(): array
    {
        return json_decode((string) file_get_contents(base_path('../moderation/test_cases.json')), true);
    }

    public function test_every_blocked_case_is_caught(): void
    {
        $this->assertSame([], array_values(array_filter($this->cases()['blocked'], fn ($t) => ! BlockedWords::contains($t))));
    }

    public function test_innocent_text_is_never_blocked(): void
    {
        $this->assertSame([], array_values(array_filter($this->cases()['allowed'], fn ($t) => BlockedWords::contains($t))));
        $this->assertFalse(BlockedWords::contains(null));
    }

    public function test_the_list_is_the_shared_file_and_the_browser_gets_the_same_one(): void
    {
        $json = json_decode((string) file_get_contents(base_path('../moderation/blocked_words.json')), true);
        $this->assertSame('Please keep your message respectful.', BlockedWords::message());
        $this->assertSame($json['words'], BlockedWords::clientData()['words']);
        $this->assertSame($json['roots'], BlockedWords::clientData()['roots']);
    }

    public function test_a_missing_list_is_an_error_never_a_silent_pass(): void
    {
        config(['melai.moderation.words_file' => base_path('does-not-exist.json')]);
        BlockedWords::flush();
        try {
            $this->expectException(\RuntimeException::class);
            BlockedWords::contains('anything');
        } finally {
            config(['melai.moderation.words_file' => base_path('../moderation/blocked_words.json')]);
            BlockedWords::flush();
        }
    }
}
