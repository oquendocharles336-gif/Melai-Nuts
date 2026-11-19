<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class AdminUserManagementTest extends TestCase
{
    use RefreshDatabase;

    private function admin(): User { return User::factory()->create(['role' => 'admin', 'has_access' => true]); }

    private function payload(array $o = []): array
    {
        return array_merge(['name' => 'Ana Reyes', 'email' => 'ana@example.com', 'role' => 'staff',
            'password' => 'Str0ng!Pass', 'password_confirmation' => 'Str0ng!Pass'], $o);
    }

    public function test_staff_cannot_reach_user_management(): void
    {
        $staff = User::factory()->create(['role' => 'staff', 'has_access' => true]);
        $this->assertStaffKeptOut($this->actingAs($staff)->get('/admin/users'));
        $this->assertDatabaseMissing('users', ['email' => 'ana@example.com']);
    }

    public function test_the_website_creates_no_staff_owner_or_rider_accounts(): void
    {
        // Staff, owner and rider accounts are made only in the Melai Nuts app (User Management).
        foreach (['staff', 'admin', 'driver'] as $role) {
            $this->actingAs($this->admin())->post('/admin/users', $this->payload(['role' => $role]))->assertStatus(405);
        }
        $this->actingAs($this->admin())->get('/admin/users/create')->assertNotFound();
        $this->assertDatabaseMissing('users', ['email' => 'ana@example.com']);
    }

    public function test_admin_can_toggle_access_and_active_for_staff_not_for_admin(): void
    {
        $admin = $this->admin();
        $staff = User::factory()->create(['role' => 'staff', 'has_access' => false, 'is_active' => true]);
        $otherAdmin = User::factory()->create(['role' => 'admin']);

        $this->actingAs($admin)->post(route('admin.users.toggle-access', $staff));
        $this->assertTrue($staff->fresh()->has_access);

        $this->actingAs($admin)->post(route('admin.users.toggle-active', $staff));
        $this->assertFalse($staff->fresh()->is_active);

        $this->actingAs($admin)->post(route('admin.users.toggle-access', $otherAdmin))->assertForbidden();
    }
}
