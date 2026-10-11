<?php

namespace Tests\Unit;

use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\Auth\AccountLinkStatus;
use App\Services\Auth\LinkState;
use App\Services\Supabase\StaffIdentity;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Mockery;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/** Every link state, decided from (faked) Supabase answers for a verified Firebase identity. */
class AccountLinkStatusTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        (new FakeFirebase)->install();
    }

    /** $byEmail: what staff_registration_for_my_email() answers (the e-mail fallback lookup). */
    private function identity(array|\Throwable $ctx, array $byEmail = ['found' => false]): void
    {
        $m = Mockery::mock(StaffIdentity::class)->makePartial();
        $m->shouldReceive('contextFor')->andReturnUsing(fn () => $ctx instanceof \Throwable ? throw $ctx : $ctx);
        $m->shouldReceive('registrationByEmail')->andReturn($byEmail);
        $this->app->instance(StaffIdentity::class, $m);
    }

    private function profile(string $role = 'staff', string $email = 'pat@example.com', array $extra = []): array
    {
        return ['status' => 'active', 'profile' => array_merge(['firebase_uid' => 'uid-p', 'full_name' => 'Pat', 'email' => $email, 'role' => $role,
            'branch_id' => 'b1', 'branch_name' => 'Calamba'], $extra), 'authorized_branches' => []];
    }

    private function user(string $role = 'staff', array $attrs = []): User
    {
        $u = User::factory()->create(array_merge(['email' => 'pat@example.com', 'role' => $role, 'has_access' => false], $attrs));
        $u->forceFill(['firebase_uid' => 'uid-p'])->save();

        return $u;
    }

    private function claims(array $o = []): array
    {
        return array_merge(['sub' => 'uid-p', 'email' => 'pat@example.com', 'email_verified' => false, 'exp' => time() + 3600], $o);
    }

    private function state(User $u, array $claims = [], bool $promote = false): array
    {
        return app(AccountLinkStatus::class)->evaluate($u, $this->claims($claims), link: true, promoteOwner: $promote);
    }

    public function test_linked_successfully_grants_access_and_saves_the_uid(): void
    {
        $this->identity($this->profile());
        $u = $this->user();
        $this->assertSame(LinkState::LINKED, $this->state($u)['state']);
        $this->assertSame('uid-p', $u->fresh()->staff_uid);
        $this->assertTrue($u->fresh()->has_access);
    }

    public function test_existing_valid_link_is_kept(): void
    {
        $this->identity($this->profile());
        $u = $this->user('staff', ['has_access' => true]);
        $u->forceFill(['staff_uid' => 'uid-p', 'staff_linked_at' => now()->subYear()])->save();
        $this->assertSame(LinkState::LINKED, $this->state($u)['state']);
        $this->assertTrue($u->fresh()->staff_linked_at->lt(now()->subMonth()), 'link must not be rewritten');
    }

    public function test_app_profile_missing(): void
    {
        $this->identity(['status' => 'not_provisioned']);
        $u = $this->user();
        $r = $this->state($u);
        $this->assertSame(LinkState::PROFILE_MISSING, $r['state']);
        $this->assertStringContainsString('approve', $r['message']);
        $this->assertNull($u->fresh()->staff_uid);
    }

    public function test_missing_profile_falls_back_to_the_email_and_names_the_exact_problem(): void
    {
        // A staff row exists for this e-mail, but under another Firebase UID: nothing is linked by e-mail alone.
        $this->identity(['status' => 'not_provisioned'], ['found' => true, 'same_uid' => false, 'role' => 'owner', 'account_status' => 'active']);
        $u = $this->user('admin', ['has_access' => true]);
        $r = $this->state($u, promote: true);
        $this->assertSame(LinkState::PROFILE_MISSING, $r['state']);
        $this->assertStringContainsString('as an owner, but under a different Firebase account', $r['message']);
        $this->assertNull($u->fresh()->staff_uid);

        // No row for the e-mail either: says which registry is missing it.
        $this->identity(['status' => 'not_provisioned']);
        $this->assertStringContainsString('staff_members', $this->state($u)['message']);
    }

    public function test_auto_linker_refuses_with_the_reason_but_lets_a_pending_registration_wait(): void
    {
        config(['melai.data_source' => 'supabase']);
        $this->identity(['status' => 'not_provisioned']);
        $linker = app(\App\Services\Auth\AutoLinker::class);

        $pending = $this->user('staff', ['has_access' => false]);
        $this->assertSame(LinkState::PROFILE_MISSING, $linker->linkAtLogin($pending, $this->claims())['state']);

        $admin = User::factory()->create(['email' => 'adm@example.com', 'role' => 'admin', 'has_access' => true]);
        try {
            $linker->linkAtLogin($admin, $this->claims(['sub' => 'uid-adm', 'email' => 'adm@example.com']));
            $this->fail('expected the sign-in to be refused');
        } catch (\App\Exceptions\AccountLinkException $e) {
            $this->assertSame(LinkState::PROFILE_MISSING, $e->state);
            $this->assertStringStartsWith('App profile missing:', $e->getMessage());
        }

        $this->assertTrue(\App\Models\ActivityLog::where('action', 'auth.autolink_failed')->where('user_id', $admin->id)->exists());
    }

    public function test_branch_assignment_missing(): void
    {
        $this->identity(['status' => 'invalid_branch']);
        $this->assertSame(LinkState::BRANCH_MISSING, $this->state($this->user())['state']);
    }

    public function test_inactive_or_suspended_account_is_not_authorized(): void
    {
        foreach (['inactive' => 'deactivated', 'suspended' => 'suspended'] as $status => $word) {
            $this->identity(['status' => $status]);
            $u = User::factory()->create(['email' => "pat-$status@example.com", 'role' => 'staff']);
            $u->forceFill(['firebase_uid' => "uid-$status"])->save();
            $r = $this->state($u, ['sub' => "uid-$status", 'email' => "pat-$status@example.com"]);
            $this->assertSame(LinkState::ROLE_NOT_AUTHORIZED, $r['state']);
            $this->assertStringContainsString($word, $r['message']);
        }
    }

    public function test_email_mismatch_never_links(): void
    {
        $this->identity($this->profile('staff', 'someone-else@example.com'));
        $u = $this->user();
        $this->assertSame(LinkState::EMAIL_MISMATCH, $this->state($u)['state']);
        $this->assertSame(LinkState::EMAIL_MISMATCH, $this->state($u, ['email' => 'other@example.com'])['state']);
        $this->assertNull($u->fresh()->staff_uid);
    }

    public function test_login_linked_to_another_app_account_is_a_mismatch(): void
    {
        $this->identity($this->profile());
        $u = $this->user();
        $u->forceFill(['staff_uid' => 'someone-else'])->save();
        $this->assertSame(LinkState::EMAIL_MISMATCH, $this->state($u)['state']);
        $this->assertSame('someone-else', $u->fresh()->staff_uid);
    }

    public function test_admin_login_needs_an_owner_account_and_staff_cannot_become_admin(): void
    {
        $this->identity($this->profile('staff'));
        $admin = $this->user('admin');
        $this->assertSame(LinkState::ROLE_NOT_AUTHORIZED, $this->state($admin)['state']);
        $this->assertSame('admin', $admin->fresh()->role);

        // A staff login whose app account is staff stays staff, even with promotion allowed.
        $this->identity($this->profile('staff', 'sam@example.com', ['firebase_uid' => 'uid-s']));
        $staff = User::factory()->create(['email' => 'sam@example.com', 'role' => 'staff']);
        $staff->forceFill(['firebase_uid' => 'uid-s'])->save();
        app(AccountLinkStatus::class)->evaluate($staff, $this->claims(['sub' => 'uid-s', 'email' => 'sam@example.com']), true, true);
        $this->assertSame('staff', $staff->fresh()->role);
    }

    public function test_verified_app_owner_promotes_an_unlinked_staff_login_only_at_sign_in(): void
    {
        $this->identity($this->profile('owner', 'pat@example.com', ['branch_id' => null, 'branch_name' => null]));
        $u = $this->user('staff');
        $this->assertSame(LinkState::ROLE_NOT_AUTHORIZED, $this->state($u, [], promote: false)['state']);
        $this->assertSame(LinkState::LINKED, $this->state($u, [], promote: true)['state']);
        $this->assertSame('admin', $u->fresh()->role);
    }

    public function test_already_linked_staff_login_is_promoted_when_its_app_account_became_owner(): void
    {
        $this->identity($this->profile('owner', 'pat@example.com', ['branch_id' => null, 'branch_name' => null]));
        $u = $this->user('staff', ['has_access' => true]);
        $u->forceFill(['staff_uid' => 'uid-p'])->save();

        $this->assertSame(LinkState::ROLE_NOT_AUTHORIZED, $this->state($u, [], promote: false)['state']);
        $this->assertSame(LinkState::LINKED, $this->state($u, [], promote: true)['state']);
        $this->assertSame('admin', $u->fresh()->role);
        $this->assertSame('uid-p', $u->fresh()->staff_uid);
    }

    public function test_login_linked_to_another_app_account_is_never_promoted(): void
    {
        $this->identity($this->profile('owner', 'pat@example.com', ['branch_id' => null, 'branch_name' => null]));
        $u = $this->user('staff');
        $u->forceFill(['staff_uid' => 'someone-else'])->save();

        $this->assertSame(LinkState::EMAIL_MISMATCH, $this->state($u, [], promote: true)['state']);
        $this->assertSame('staff', $u->fresh()->role);
    }

    public function test_unverified_email_when_verification_is_required(): void
    {
        config(['services.firebase.require_verified_email' => true]);
        $this->identity($this->profile());
        $u = $this->user();
        $this->assertSame(LinkState::EMAIL_NOT_VERIFIED, $this->state($u)['state']);
        $this->assertNull($u->fresh()->staff_uid);
        $this->assertSame(LinkState::LINKED, $this->state($u, ['email_verified' => true])['state']);
    }

    public function test_database_unreachable_is_a_temporary_error(): void
    {
        $this->identity(new BackendUnavailableException('The Melai Nuts database could not be reached.'));
        $this->assertSame(LinkState::TEMPORARY_ERROR, $this->state($this->user())['state']);
    }

    public function test_configuration_missing_and_not_authenticated(): void
    {
        $u = $this->user();
        config(['services.firebase.web_api_key' => null]);
        $r = app(AccountLinkStatus::class)->resolve($u);
        $this->assertSame(LinkState::CONFIG_MISSING, $r['state']);
        $this->assertStringContainsString('FIREBASE_WEB_API_KEY', $r['message']);

        config(['services.firebase.web_api_key' => FakeFirebase::API_KEY]);
        $this->assertSame(LinkState::NOT_AUTHENTICATED, app(AccountLinkStatus::class)->resolve($u)['state']);
    }
}
