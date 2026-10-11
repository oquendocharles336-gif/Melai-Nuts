<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Links an admin-portal login to the Melai Nuts app account it acts as in Supabase
     * (staff_members.firebase_uid = the person's Firebase UID). Null = not linked: the user
     * can sign in, but pages backed by the shared database show "not linked" instead of data.
     */
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->string('staff_uid', 128)->nullable()->unique()->after('role');
            $table->timestamp('staff_linked_at')->nullable()->after('staff_uid');
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropUnique(['staff_uid']);
            $table->dropColumn(['staff_uid', 'staff_linked_at']);
        });
    }
};
