<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Which version of the Terms and Privacy Policy a website login accepted at registration, and when. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            if (! Schema::hasColumn('users', 'terms_version')) {
                $table->string('terms_version', 40)->nullable();
                $table->timestamp('terms_accepted_at')->nullable();
            }
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropColumn(['terms_version', 'terms_accepted_at']);
        });
    }
};
