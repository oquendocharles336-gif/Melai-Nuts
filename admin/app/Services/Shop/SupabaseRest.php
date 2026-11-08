<?php

namespace App\Services\Shop;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * The shop's only way to reach Supabase: the same public API the Melai Nuts app uses.
 *
 * Guests call it with the public (anon) key, exactly like the app before sign-in. A signed-in
 * customer calls it with their own Firebase ID token, exactly like the app after sign-in, so
 * Row Level Security and every SQL function (cart, place_order, downpayment) treat a website
 * customer and an app customer the same way.
 *
 * It never uses the admin website's staff database login (SupabaseGateway); a customer request
 * cannot reach anything the app itself could not.
 */
class SupabaseRest
{
    public function configured(): bool
    {
        return filled($this->url()) && filled($this->anonKey());
    }

    /** Base project URL, e.g. https://abc.supabase.co (no trailing slash). */
    public function url(): string
    {
        return rtrim((string) config('melai.shop.supabase_url'), '/');
    }

    private function anonKey(): string
    {
        return (string) config('melai.shop.anon_key');
    }

    /**
     * GET /rest/v1/{table}?{query}. $query is PostgREST syntax, e.g. ['select' => '*', 'is_active' => 'eq.true'].
     *
     * @return array<int, array<string, mixed>>
     */
    public function select(string $table, array $query, ?string $idToken = null): array
    {
        $r = $this->send(fn () => $this->client($idToken)->get($this->url().'/rest/v1/'.$table, $query));

        return is_array($r->json()) ? $r->json() : [];
    }

    /** POST /rest/v1/rpc/{fn}. Returns the decoded JSON body (scalar, array or null). */
    public function rpc(string $fn, array $params = [], ?string $idToken = null): mixed
    {
        $r = $this->send(fn () => $this->client($idToken)->post($this->url().'/rest/v1/rpc/'.$fn, (object) $params));

        return $r->json();
    }

    /** INSERT one row as the signed-in customer; returns the stored row. */
    public function insert(string $table, array $row, string $idToken): array
    {
        $r = $this->send(fn () => $this->client($idToken)->withHeaders(['Prefer' => 'return=representation'])
            ->post($this->url().'/rest/v1/'.$table, $row));
        $rows = $r->json();

        return is_array($rows) && isset($rows[0]) ? $rows[0] : [];
    }

    /** PATCH rows matching $filter (PostgREST syntax) as the signed-in customer. */
    public function update(string $table, array $filter, array $values, string $idToken): array
    {
        $r = $this->send(fn () => $this->client($idToken)->withHeaders(['Prefer' => 'return=representation'])
            ->patch($this->url().'/rest/v1/'.$table.'?'.http_build_query($filter), $values));

        return is_array($r->json()) ? $r->json() : [];
    }

    /**
     * Call an Edge Function as the customer (e.g. hitpay-create-payment). Returns the JSON body;
     * an error status throws ShopException with the function's own message when it gave one.
     */
    public function invoke(string $function, array $body, string $idToken): array
    {
        $r = $this->send(fn () => $this->client($idToken)->timeout(25)->post($this->url().'/functions/v1/'.$function, $body), function: true);

        return is_array($r->json()) ? $r->json() : [];
    }

    private function client(?string $idToken): PendingRequest
    {
        if (! $this->configured()) {
            throw new ShopException('The shop is not set up yet. Please try again later.', 'not_configured');
        }

        return Http::acceptJson()->asJson()->timeout(15)->withHeaders([
            'apikey' => $this->anonKey(),
            'Authorization' => 'Bearer '.($idToken ?: $this->anonKey()),
        ]);
    }

    /** Runs a request; network trouble and error answers become a customer-safe ShopException. */
    private function send(\Closure $request, bool $function = false): Response
    {
        try {
            $r = $request();
        } catch (ConnectionException $e) {
            throw new ShopException('We couldn\'t reach the shop right now. Please check your connection and try again.', 'offline', previous: $e);
        }
        if ($r->successful()) {
            return $r;
        }

        $body = $r->json();
        $code = is_array($body) ? (string) ($body['code'] ?? '') : '';
        $message = is_array($body) ? (string) ($body['message'] ?? $body['error'] ?? '') : '';
        Log::info('[shop] supabase refused', ['status' => $r->status(), 'code' => $code]);

        if ($r->status() === 401 || $code === 'PGRST301' || $code === 'PGRST302') {
            throw new ShopException('Your sign-in has ended. Please sign in again.', 'session', $r->status());
        }
        // P0001 = RAISE EXCEPTION in our SQL functions: the text is written for customers
        // (stock, branch, voucher, points). Edge Functions return customer-facing { error }.
        if (($code === 'P0001' || $function) && $message !== '' && $r->status() < 500) {
            throw new ShopException($message, 'refused', $r->status());
        }
        if ($r->serverError()) {
            throw new ShopException('The shop is having trouble right now. Please try again in a moment.', 'server', $r->status());
        }

        throw new ShopException('We couldn\'t complete that. Please try again.', 'refused', $r->status());
    }
}
