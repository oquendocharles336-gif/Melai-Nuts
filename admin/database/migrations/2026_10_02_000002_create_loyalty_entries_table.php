<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Local points ledger layered on top of the Firestore-side pointsHistory (same pattern as
     * order_overrides): manual admin add/deduct, COD orders the admin marks paid here (earn),
     * and refund deductions. order_id is unique per "earned" entry so awarding is idempotent.
     */
    public function up(): void
    {
        Schema::create('loyalty_entries', function (Blueprint $table) {
            $table->id();
            $table->string('member_id');
            $table->string('member_name');
            $table->string('type', 20); // earned | redeemed | refunded | adjusted
            $table->integer('points'); // whole number; negative for deductions
            $table->string('order_id')->nullable(); // set for earned/refunded entries, null for manual adjustments
            $table->text('reason')->nullable(); // required for manual adjustments
            $table->boolean('flagged_negative')->default(false); // balance went below zero after a refund deduction
            $table->foreignId('created_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamps();

            $table->unique(['member_id', 'order_id', 'type']); // one earned/refunded entry per order per member
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('loyalty_entries');
    }
};
