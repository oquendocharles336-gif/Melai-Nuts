<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Products page > Photos: when this owner allowed the website to read the photo files they choose
 * (the "Allow photo access" button). Null = not allowed yet / reset. Separate from the app sign-in.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            if (! Schema::hasColumn('users', 'photo_access_allowed_at')) {
                $table->timestamp('photo_access_allowed_at')->nullable();
            }
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropColumn('photo_access_allowed_at');
        });
    }
};
