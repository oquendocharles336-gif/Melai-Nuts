<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Orders themselves live in Firestore (mobile app's data) and are read-only here.
     * This table is the admin-only state Melai's website is allowed to own: refund decisions
     * and manual COD payment confirmations, keyed by the Firestore order id.
     */
    public function up(): void
    {
        Schema::create('order_overrides', function (Blueprint $table) {
            $table->id();
            $table->string('order_id')->unique();

            // Refunds: requested | approved_processing | rejected | refunded | failed
            $table->string('refund_status', 30)->nullable();
            $table->unsignedInteger('refund_amount')->nullable(); // in pesos, whole numbers
            $table->text('refund_note')->nullable(); // reject reason, or admin's manual refund note
            $table->string('refund_reference')->nullable(); // PayMongo refund id once the API accepts it
            $table->foreignId('refund_processed_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamp('refund_processed_at')->nullable();
            $table->boolean('flagged_for_stock_return')->default(false);

            // Payments: admin manually confirming a COD order was paid on delivery
            $table->boolean('cod_marked_paid')->default(false);
            $table->foreignId('cod_marked_paid_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamp('cod_marked_paid_at')->nullable();

            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('order_overrides');
    }
};
