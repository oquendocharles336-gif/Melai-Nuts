<?php

namespace App\Http\Controllers;

use App\Services\ActivityLogger;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

/**
 * RFID loyalty cards.
 *
 * The card reader (Arduino + RC522, see hardware/rfid-reader/) sends the card's UID to the
 * browser, either over USB serial (Web Serial, Chrome/Edge) or by "typing" it like a keyboard.
 * The UID is only ever POSTed (never put in a URL) and the database stores just its hash.
 * Every rule (who may register, block, unblock; one active card per customer; blocked cards
 * refused) lives in supabase/migrations/20261011000000_loyalty_cards.sql.
 */
class LoyaltyCardController extends Controller
{
    private const UID_RULE = ['required', 'string', 'max:64', 'regex:/^[0-9A-Fa-f:\-\s\.]{8,64}$/'];

    public function index(Request $request)
    {
        $isOwner = $this->identity()->isOwner();
        $q = trim((string) $request->query('q', ''));
        $status = in_array($request->query('status'), ['active', 'blocked', 'replaced'], true) ? $request->query('status') : null;

        return view('cards.index', [
            'isOwner' => $isOwner,
            'list' => $isOwner ? $this->repo()->listCards($q ?: null, $status) : null,
            'q' => $q, 'status' => $status,
        ]);
    }

    /** JSON for the reader: what is this card? */
    public function tap(Request $request): JsonResponse
    {
        $data = $request->validate(['card_uid' => self::UID_RULE]);
        $result = $this->repo()->lookupCard($data['card_uid']);
        if (($result['status'] ?? '') === 'active') {
            $result['url'] = route('cards.customer', $result['customer']['firebase_uid']);
        }

        return response()->json($result);
    }

    /** Find a customer by phone / e-mail / printed label / tapped card, then open their cards page. */
    public function find(Request $request)
    {
        $data = $request->validate(['query' => ['required', 'string', 'min:4', 'max:120']]);
        $found = $this->repo()->lookupCustomer($data['query']);
        if (count($found) === 0) {
            return back()->withInput()->with('error', 'No customer with that exact phone number, e-mail or card. (Partial searches are not allowed.)');
        }
        if (count($found) > 1) {
            return back()->withInput()->with('error', 'More than one customer matches. Use the e-mail address instead.');
        }

        return redirect()->route('cards.customer', $found[0]['firebase_uid']);
    }

    public function customer(string $uid)
    {
        abort_unless(strlen($uid) <= 128, 404);
        $member = $this->repo()->loyaltyMember($uid);
        abort_if(! $member, 404);

        return view('cards.customer', [
            'member' => $member,
            'cards' => $this->repo()->customerCards($uid),
            'isOwner' => $this->identity()->isOwner(),
            'requestKey' => Str::random(32), // a double submit registers once
        ]);
    }

    public function register(Request $request, string $uid)
    {
        $data = $request->validate(['card_uid' => self::UID_RULE, 'request_key' => ['required', 'string', 'min:8', 'max:100']]);
        $card = $this->repo()->registerCard($data['card_uid'], $uid, $data['request_key']);
        ActivityLogger::log('loyalty.card_registered', "Linked loyalty card {$card['label']} to {$card['customer_name']}", null,
            ['card_id' => $card['id'], 'customer' => $uid]);

        return redirect()->route('cards.customer', $uid)->with('status', "Card {$card['label']} is now linked. The customer was notified in the app.");
    }

    public function replace(Request $request, string $uid)
    {
        $data = $request->validate([
            'card_uid' => self::UID_RULE,
            'reason' => ['required', 'string', 'min:3', 'max:200'],
            'request_key' => ['required', 'string', 'min:8', 'max:100'],
        ]);
        $card = $this->repo()->replaceCard($uid, $data['card_uid'], $data['reason'], $data['request_key']);
        ActivityLogger::log('loyalty.card_replaced', "Replaced loyalty card for {$card['customer_name']} with {$card['label']}", null,
            ['card_id' => $card['id'], 'customer' => $uid, 'reason' => $data['reason']]);

        return redirect()->route('cards.customer', $uid)->with('status', "New card {$card['label']} is active. The old card no longer works; the points were kept.");
    }

    public function block(Request $request, string $card)
    {
        abort_unless(Str::isUuid($card), 404);
        $data = $request->validate(['reason' => ['required', 'string', 'min:3', 'max:200']]);
        $result = $this->repo()->blockCard($card, $data['reason']);
        ActivityLogger::log('loyalty.card_blocked', "Blocked loyalty card {$result['label']}", null,
            ['card_id' => $card, 'customer' => $result['firebase_uid'], 'reason' => $data['reason']]);

        return redirect()->route('cards.customer', $result['firebase_uid'])->with('status', "Card {$result['label']} is blocked. It can no longer be used to earn or redeem points.");
    }

    public function unblock(string $card)
    {
        abort_unless(Str::isUuid($card), 404);
        $result = $this->repo()->unblockCard($card);
        ActivityLogger::log('loyalty.card_unblocked', "Unblocked loyalty card {$result['label']}", null,
            ['card_id' => $card, 'customer' => $result['firebase_uid']]);

        return redirect()->route('cards.customer', $result['firebase_uid'])->with('status', "Card {$result['label']} works again.");
    }
}
