<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Loyalty Cards > Archive on the owner website (blocked / replaced cards: re-activate, delete with
 * a confirm step, "deletes in N days"). The database rules are tested in
 * supabase/tests/loyalty_card_archive_test.sql.
 */
class LoyaltyCardArchiveTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private const ACTIVE = '11111111-1111-4111-8111-111111111111';
    private const BLOCKED = '22222222-2222-4222-8222-222222222222';
    private const RETIRED = '33333333-3333-4333-8333-333333333333';

    protected function setUp(): void
    {
        parent::setUp();
        $this->useFakeSupabase();
        $card = fn ($id, $label, $status, $uid, $name, $days = null, $hasActive = false) => [
            'id' => $id, 'label' => $label, 'status' => $status, 'firebase_uid' => $uid, 'customer_name' => $name,
            'email' => $uid.'@example.com', 'phone' => null, 'points_balance' => 120, 'issued_at' => '2026-11-01T02:00:00Z',
            'issued_branch' => 'Calamba Branch', 'blocked_at' => $status === 'blocked' ? '2026-11-15T02:00:00Z' : null,
            'block_reason' => $status === 'blocked' ? 'reported lost' : null, 'replaced_by' => null,
            'archived_at' => $days === null ? null : '2026-11-15T02:00:00Z', 'days_left' => $days, 'has_active_card' => $hasActive,
        ];
        $this->db->cards = [
            self::ACTIVE => $card(self::ACTIVE, 'GK-AAAA-0001', 'active', 'c-two', 'Ben Santos'),
            self::BLOCKED => $card(self::BLOCKED, 'GK-BBBB-0002', 'blocked', 'c-one', 'Ana Dela Cruz', 24),
            self::RETIRED => $card(self::RETIRED, 'GK-CCCC-0003', 'replaced', 'c-two', 'Ben Santos', 1, true),
        ];
    }

    private ?\App\Models\User $ownerLogin = null;

    private function owner(): static
    {
        return $this->signedIn($this->ownerLogin ??= $this->linkedLogin('uid-owner'));
    }

    public function test_the_owner_sees_the_archive_with_days_left_and_the_card_list_is_unchanged(): void
    {
        $this->owner()->get('/cards')->assertOk()
            ->assertSee('All cards')->assertSee('GK-AAAA-0001')       // the existing list is still there
            ->assertSee('id="archive"', false)->assertSee('data-card-archive', false)
            ->assertSeeInOrder(['Archive', 'GK-BBBB-0002', 'reported lost', '24 days', 'GK-CCCC-0003', '1 day'])
            ->assertSee(route('cards.reactivate', self::BLOCKED), false)
            ->assertSee(route('cards.destroy', self::BLOCKED), false)
            ->assertSee('Has an active card');                     // the retired card cannot come back yet
        $this->assertContains('owner_archived_loyalty_cards', $this->db->calledFunctions('uid-owner'));
    }

    public function test_re_activate_from_the_archive(): void
    {
        $this->owner()->post('/cards/'.self::BLOCKED.'/reactivate')
            ->assertRedirect(route('cards.index').'#archive')->assertSessionHas('status', 'Card GK-BBBB-0002 works again.');
        $this->assertSame('active', $this->db->cards[self::BLOCKED]['status']);
        $this->assertDatabaseHas('activity_logs', ['action' => 'loyalty.card_reactivated']);
    }

    public function test_delete_needs_the_card_label_typed_again(): void
    {
        $this->owner()->post('/cards/'.self::RETIRED.'/delete', [])->assertSessionHasErrors('confirm_label');
        $this->owner()->post('/cards/'.self::RETIRED.'/delete', ['confirm_label' => 'GK-0000-0000']);
        $this->assertArrayHasKey(self::RETIRED, $this->db->cards, 'a wrong label deletes nothing');

        $this->owner()->post('/cards/'.self::RETIRED.'/delete', ['confirm_label' => 'gk-cccc-0003'])
            ->assertRedirect(route('cards.index').'#archive')
            ->assertSessionHas('status', "Card GK-CCCC-0003 was deleted. The customer's points were kept.");
        $this->assertArrayNotHasKey(self::RETIRED, $this->db->cards);
        $this->assertSame(['uid-owner'], array_values(array_unique(array_column(array_filter($this->db->calls,
            fn ($c) => $c['fn'] === 'owner_delete_archived_card'), 'uid'))), 'deleted as the signed-in owner');
        $this->assertDatabaseHas('activity_logs', ['action' => 'loyalty.card_deleted']);
    }

    public function test_staff_cannot_use_the_archive(): void
    {
        $staff = $this->signedIn($this->linkedLogin('uid-cal'));
        // Staff never get the archive (the existing page rules may send them elsewhere), and the
        // actions refuse them even when called directly.
        $this->assertStringNotContainsString('data-card-archive', $staff->get('/cards')->getContent());
        $this->assertContains($staff->post('/cards/'.self::BLOCKED.'/reactivate')->getStatusCode(), [302, 403]);
        $this->assertContains($staff->post('/cards/'.self::BLOCKED.'/delete', ['confirm_label' => 'GK-BBBB-0002'])->getStatusCode(), [302, 403]);
        $this->assertNotContains('owner_reactivate_archived_card', $this->db->calledFunctions());
        $this->assertNotContains('owner_delete_archived_card', $this->db->calledFunctions());
        $this->assertSame('blocked', $this->db->cards[self::BLOCKED]['status']);
        $this->assertArrayHasKey(self::BLOCKED, $this->db->cards);
    }

    public function test_the_cards_page_still_works_before_the_database_update(): void
    {
        $this->db->missing = ['owner_archived_loyalty_cards'];
        $this->owner()->get('/cards')->assertOk()->assertSee('GK-AAAA-0001')
            ->assertSee('The archive needs the latest database update')->assertDontSee('data-card-archive', false);
    }
}
