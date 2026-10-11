<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The Firebase Authentication account a website login signs in with (website-local table only;
     * nothing changes in Supabase or Firebase).
     *
     *  firebase_uid             Firebase UID proven by a verified ID token. Once set, the login signs in
     *                           only through Firebase (its local password is replaced by a random one).
     *  firebase_email_verified  email_verified claim of the last verified token (owners approve only
     *                           website registrations whose email Firebase has verified).
     *
     * staff_uid (2026_10_09) stays the link to the app's staff registry (staff_members.firebase_uid);
     * for a linked login both columns hold the same UID.
     */
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->string('firebase_uid', 128)->nullable()->unique()->after('staff_linked_at');
            $table->boolean('firebase_email_verified')->default(false)->after('firebase_uid');
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropUnique(['firebase_uid']);
            $table->dropColumn(['firebase_uid', 'firebase_email_verified']);
        });
    }
};
