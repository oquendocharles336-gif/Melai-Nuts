<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;

class User extends Authenticatable
{
    use HasFactory, Notifiable;

    public const ROLE_ADMIN = 'admin';
    public const ROLE_STAFF = 'staff';

    /**
     * The only roles that may sign in to the website. Delivery riders use the Melai Nuts app only;
     * an old website login with any other role (left in the users table, never deleted) is refused.
     */
    public const WEBSITE_ROLES = [self::ROLE_ADMIN, self::ROLE_STAFF];

    // role / has_access / is_active / staff_uid / firebase_uid are NOT fillable on purpose (no mass-assignment tricks).
    protected $fillable = ['name', 'email', 'password'];
    protected $hidden = ['password', 'remember_token', 'two_factor_secret', 'two_factor_recovery_codes'];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'last_login_at' => 'datetime',
            'staff_linked_at' => 'datetime',
            'password' => 'hashed', // bcrypt (config/hashing.php)
            'is_active' => 'boolean',
            'has_access' => 'boolean',
            'firebase_email_verified' => 'boolean',
            'two_factor_secret' => 'encrypted',
            'two_factor_recovery_codes' => 'encrypted:array',
            'two_factor_confirmed_at' => 'datetime',
        ];
    }

    /** Two-step sign-in is on (the authenticator was confirmed). */
    public function hasTwoFactor(): bool
    {
        return $this->two_factor_confirmed_at !== null && filled($this->two_factor_secret);
    }

    /** Signs in through Firebase (its local password is no longer accepted). */
    public function usesFirebase(): bool
    {
        return filled($this->firebase_uid);
    }

    /** May this login use the website at all (sign in, keep a session)? */
    public function canUseWebsite(): bool
    {
        return in_array($this->role, self::WEBSITE_ROLES, true);
    }

    public function isAdmin(): bool
    {
        return $this->role === self::ROLE_ADMIN;
    }
}
