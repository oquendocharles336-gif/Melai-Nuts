<?php

namespace Tests\Support;

use App\Models\User;
use App\Services\Supabase\SupabaseGateway;

/**
 * DATA_SOURCE=supabase feature tests without a database server: Firebase is FakeFirebase (real
 * signed tokens) and Supabase is FakeSupabase (scoped answers per calling UID). The app accounts
 * of the FakeSupabase staff fixtures exist in Firebase with the password "<uid>#Pass1".
 */
trait UsesFakeSupabase
{
    protected FakeFirebase $fb;
    protected FakeSupabase $db;

    protected function useFakeSupabase(): void
    {
        config(['melai.data_source' => 'supabase']);
        if (! isset($this->fb)) { // one FakeFirebase per test (Http fakes match in registration order)
            $this->fb = (new FakeFirebase)->install();
        }
        $this->db = FakeSupabase::make();
        $this->app->instance(SupabaseGateway::class, $this->db);
        foreach ($this->db->staff as $uid => $s) {
            $this->fb->addAccount($s['email'], $uid, "$uid#Pass1", verified: true);
        }
    }

    /** A website login already linked to the app account $uid. */
    protected function linkedLogin(string $uid, array $attrs = []): User
    {
        $s = $this->db->staff[$uid];
        $u = User::factory()->create(array_merge(['email' => $s['email'], 'name' => $s['full_name'],
            'role' => $s['role'] === 'owner' ? 'admin' : 'staff', 'has_access' => true], $attrs));
        $u->forceFill(['firebase_uid' => $uid, 'staff_uid' => $uid, 'firebase_email_verified' => true])->save();

        return $u;
    }

    /** Signed in to the website AND holding a Firebase sign-in for the login's app account. */
    protected function signedIn(User $user, int $expiresIn = 3600): static
    {
        return $this->actingAs($user)->withSession($this->fb->sessionFor($user, $expiresIn));
    }
}
