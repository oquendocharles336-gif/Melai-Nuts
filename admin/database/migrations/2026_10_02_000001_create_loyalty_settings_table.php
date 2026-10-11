<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /** Single-row table of admin-editable loyalty rules (Supabase-style admin-only settings). */
    public function up(): void
    {
        Schema::create('loyalty_settings', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('earn_rate_pesos')->default(1); // CHANGE: pesos spent per 1 point earned
            $table->unsignedInteger('redeem_points_per_peso')->default(10); // CHANGE: points needed per PHP 1 off (default 100 pts = PHP 10)
            $table->unsignedInteger('max_redeem_per_order')->default(500); // CHANGE: max points redeemable on one order
            $table->unsignedInteger('expiry_months')->default(12); // CHANGE: points expire after this many months
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('loyalty_settings');
    }
};
