<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use App\Services\Supabase\SupabaseGateway;
use Database\Seeders\AdminSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Mockery;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/**
 * php artisan melai:change-admin-email: the existing "Melai Admin" login gets the new email in
 * place (same id, password, role, access, history) and is re-linked to the app owner with that
 * email. Supabase is faked: uid-old = owner row under the old email, uid-new = owner kanzeki69@gmail.com.
 */
class ChangeAdminEmailTest extends TestCase
{
    use RefreshDatabase;

    private const OLD = 'old.admin@example.com';
    private const NEW = 'kanzeki69@gmail.com';
    private const PASSWORD = 'Adm1n!Pass#2026';

    protected function setUp(): void
    {
        parent::setUp();
        (new FakeFirebase)->install(); // no Firebase account for these emails -> local password login
        config(['melai.admin.name' => 'Melai Admin', 'melai.admin.email' => self::OLD,
            'melai.admin.password' => self::PASSWORD, 'melai.admin.staff_uid' => null]);
    }

    /** Fake Supabase. $owners: uid => [email, status]. The directory lists them all. */
    private function supabase(array $owners = ['uid-old' => [self::OLD, 'active'], 'uid-new' => [self::NEW, 'active']]): void
    {
        config(['melai.data_source' => 'supabase']);
        $profile = fn ($uid) => ['firebase_uid' => $uid, 'full_name' => 'Melai Nuts', 'email' => $owners[$uid][0],
            'role' => 'owner', 'branch_id' => null, 'branch_name' => null, 'is_active' => true, 'account_status' => 'active'];
        $m = Mockery::mock(SupabaseGateway::class);
        $m->shouldReceive('call')->andReturnUsing(function (string $uid, string $sql) use ($owners, $profile) {
            if (str_contains($sql, 'admin_portal_staff_directory')) {
                return array_map($profile, array_keys($owners));
            }

            return isset($owners[$uid])
                ? ['status' => $owners[$uid][1], 'profile' => $profile($uid), 'authorized_branches' => [['id' => 'b1', 'name' => 'Calamba Branch']]]
                : ['status' => 'not_provisioned'];
        });
        // Server-side link at sign-in / seeding: which owner row has this e-mail (portal_staff_uid_for_email).
        $m->shouldReceive('staffUidForEmail')->andReturnUsing(function (string $email) use ($owners) {
            $uid = collect($owners)->search(fn ($o) => $o[0] === $email);

            return $uid === false ? ['status' => 'none'] : ['status' => 'found', 'firebase_uid' => $uid, 'account_status' => $owners[$uid][1]];
        });
        $this->app->instance(SupabaseGateway::class, $m);
    }

    private function admin(array $extra = []): User
    {
        $u = User::factory()->create(['name' => 'Melai Admin', 'email' => self::OLD, 'password' => self::PASSWORD,
            'role' => 'admin', 'is_active' => true, 'has_access' => true]);
        $u->forceFill($extra)->save();
        ActivityLog::create(['user_id' => $u->id, 'action' => 'auth.login', 'description' => 'Logged in']);

        return $u;
    }

    public function test_changes_the_same_user_keeps_role_password_history_and_relinks_the_owner(): void
    {
        $this->supabase();
        $admin = $this->admin(['staff_uid' => 'uid-old', 'staff_linked_at' => now(), 'remember_token' => 'old-token']);

        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => '  KANZEKI69@Gmail.com '])
            ->expectsOutputToContain('old.admin@example.com -> kanzeki69@gmail.com')
            ->expectsOutputToContain('get_my_staff_context() status: active')
            ->assertSuccessful();

        $u = User::find($admin->id);
        $this->assertSame(self::NEW, $u->email);
        $this->assertSame('admin', $u->role);
        $this->assertTrue($u->is_active && $u->has_access);
        $this->assertTrue(Hash::check(self::PASSWORD, $u->password));
        $this->assertSame('uid-new', $u->staff_uid);   // old owner (other email) unlinked, new owner linked
        $this->assertNotNull($u->email_verified_at);
        $this->assertNotSame('old-token', $u->remember_token);
        $this->assertSame(1, User::where('role', 'admin')->count());
        $this->assertSame(0, User::where('email', self::OLD)->count());
        $this->assertTrue(ActivityLog::where('user_id', $u->id)->where('action', 'auth.login')->exists()); // history kept
        $this->assertTrue(ActivityLog::where('user_id', $u->id)->where('description', 'Admin email changed')->exists());
    }

    public function test_link_already_pointing_at_the_new_email_owner_is_kept(): void
    {
        $this->supabase(['uid-new' => [self::NEW, 'active']]);
        $admin = $this->admin(['staff_uid' => 'uid-new', 'firebase_uid' => 'uid-new']);

        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => self::NEW])->assertSuccessful();

        $u = $admin->fresh();
        $this->assertSame('uid-new', $u->staff_uid);
        $this->assertSame('uid-new', $u->firebase_uid);
    }

    public function test_old_email_can_no_longer_log_in_new_one_can_and_reaches_the_dashboard_with_data(): void
    {
        $this->supabase();
        $admin = $this->admin(['staff_uid' => 'uid-old']);
        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => self::NEW])->assertSuccessful();
        config(['melai.data_source' => 'mock', 'melai.admin.email' => self::NEW]);

        $this->post('/login', ['email' => self::OLD, 'password' => self::PASSWORD])->assertSessionHasErrors();
        $this->assertGuest();

        $this->post('/login', ['email' => self::NEW, 'password' => self::PASSWORD])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($admin->fresh());
        $this->get('/dashboard')->assertOk()->assertSee('Sales per branch')->assertSee('Calamba Branch');
    }

    public function test_duplicate_email_is_refused_and_nothing_changes(): void
    {
        $this->supabase();
        $admin = $this->admin();
        User::factory()->create(['email' => self::NEW, 'role' => 'staff']);

        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => 'Kanzeki69@gmail.com'])
            ->expectsOutputToContain('Another login already uses kanzeki69@gmail.com')
            ->assertFailed();
        $this->assertSame(self::OLD, $admin->fresh()->email);
    }

    public function test_invalid_email_is_refused(): void
    {
        $this->supabase();
        $admin = $this->admin();
        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => 'not-an-email'])->assertFailed();
        $this->assertSame(self::OLD, $admin->fresh()->email);
    }

    public function test_falls_back_to_the_admin_named_melai_admin(): void
    {
        $this->supabase();
        $admin = $this->admin();
        $this->artisan('melai:change-admin-email', ['old' => 'unknown@example.com', 'new' => self::NEW])->assertSuccessful();
        $this->assertSame(self::NEW, $admin->fresh()->email);
    }

    public function test_existing_sessions_are_signed_out(): void
    {
        $this->supabase();
        config(['session.driver' => 'database']);
        $admin = $this->admin();
        DB::table('sessions')->insert(['id' => 'sess-1', 'user_id' => $admin->id, 'ip_address' => '127.0.0.1',
            'user_agent' => 'x', 'payload' => '', 'last_activity' => time()]);

        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => self::NEW])->assertSuccessful();
        $this->assertSame(0, DB::table('sessions')->where('user_id', $admin->id)->count());
    }

    public function test_missing_owner_in_supabase_is_reported_not_faked(): void
    {
        $this->supabase(['uid-old' => [self::OLD, 'active']]); // no owner row with the new email
        $admin = $this->admin(['staff_uid' => 'uid-old']);

        $this->artisan('melai:change-admin-email', ['old' => self::OLD, 'new' => self::NEW])
            ->expectsOutputToContain('No active owner account with the email kanzeki69@gmail.com')
            ->assertSuccessful();
        $this->assertSame(self::NEW, $admin->fresh()->email);
        $this->assertNull($admin->fresh()->staff_uid);
        $this->assertNull($admin->fresh()->email_verified_at);
    }

    public function test_seeder_with_new_admin_email_updates_the_existing_admin_instead_of_adding_one(): void
    {
        $this->supabase();
        $admin = $this->admin(['staff_uid' => 'uid-old']);
        config(['melai.admin.email' => self::NEW]);

        $this->seed(AdminSeeder::class);
        $this->seed(AdminSeeder::class); // re-running is harmless

        $this->assertSame(1, User::where('role', 'admin')->count());
        $u = $admin->fresh();
        $this->assertSame(self::NEW, $u->email);
        $this->assertTrue(Hash::check(self::PASSWORD, $u->password));
        $this->assertSame('uid-new', $u->staff_uid);
    }

    public function test_seeder_stops_instead_of_duplicating_when_the_change_is_refused(): void
    {
        config(['melai.data_source' => 'supabase']);
        $m = Mockery::mock(SupabaseGateway::class);
        $m->shouldReceive('call')->andThrow(new \App\Exceptions\BackendUnavailableException('down'));
        $this->app->instance(SupabaseGateway::class, $m);
        $this->admin(['staff_uid' => 'uid-old']);
        config(['melai.admin.email' => self::NEW]);

        try {
            $this->seed(AdminSeeder::class);
            $this->fail('Seeder should stop.');
        } catch (\RuntimeException $e) {
            $this->assertStringContainsString('melai:change-admin-email', $e->getMessage());
        }
        $this->assertSame(1, User::where('role', 'admin')->count());
        $this->assertSame(self::OLD, User::where('role', 'admin')->value('email'));
    }
}
