<?php

namespace App\Http\Controllers;

use App\Services\ActivityLogger;
use App\Services\AdminActions;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\JsonResponse;
use App\Http\Requests\ReceiveStockRequest;

/**
 * "Receive stock" on the Stock page: a new batch through the app's own staff_receive_batch
 * (needs the 'inventory' permission in the app; Supabase checks it and the branch).
 */
class StockController extends Controller
{
    public function receive(ReceiveStockRequest $request, AdminActions $actions, SupabaseRepository $repo, Platform $platform): JsonResponse
    {
        abort_unless($platform->isSupabase(), 503, 'This action needs the Melai Nuts app database.');
        $v = $request->validated(); // ReceiveStockRequest: same rules as the app's Receive Stock screen
        abort_unless(collect($platform->branches())->pluck('id')->contains($v['branch']), 422, 'Choose one of your branches.');

        $actions->receiveBatch($v['branch'], $v['variant_id'], trim($v['batch_code']), (int) $v['quantity'], $v['expiration_date']);
        ActivityLogger::log('stock.received', "Received {$v['quantity']} units (batch {$v['batch_code']})", null,
            ['branch_id' => $v['branch'], 'variant_id' => $v['variant_id'], 'quantity' => (int) $v['quantity'], 'source' => 'supabase']);

        // Read the row back from the database: the page shows what Supabase now holds, not a guess.
        $item = collect($repo->inventory($v['branch'])['items'] ?? [])->firstWhere('variant_id', $v['variant_id']);

        return response()->json([
            'message' => 'Received '.$v['quantity'].' × '.($item['product_name'] ?? 'item').'.',
            'item' => $item ? ['variant_id' => $item['variant_id'], 'quantity' => (int) $item['quantity'],
                'restock_threshold' => $item['restock_threshold'] === null ? null : (int) $item['restock_threshold'], 'batched_quantity' => (int) $item['batched_quantity']] : null,
        ]);
    }
}
