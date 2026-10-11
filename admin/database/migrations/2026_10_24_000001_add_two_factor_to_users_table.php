<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Optional two-step sign-in (TOTP, RFC 6238) for website logins. Website-local only.
     *  two_factor_secret          base32 secret, encrypted with APP_KEY (cast 'encrypted')
     *  two_factor_recovery_codes  one-time codes, stored as hashes (encrypted JSON list)
     *  two_factor_confirmed_at    set once the person proved their authenticator works; until then
     *                             two-step sign-in is NOT required
     */
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->text('two_factor_secret')->nullable();
            $table->text('two_factor_recovery_codes')->nullable();
            $table->timestamp('two_factor_confirmed_at')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropColumn(['two_factor_secret', 'two_factor_recovery_codes', 'two_factor_confirmed_at']);
        });
    }
};
