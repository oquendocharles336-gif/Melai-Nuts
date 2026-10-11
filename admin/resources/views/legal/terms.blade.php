{{-- GENERATED from lib/l10n/app_en.arb (termsS*) so the website shows the same text as the app.
     TODO(owner): sections marked "Draft wording" need the owner's confirmation (see lib/core/config/legal_config.dart). --}}
@extends('layouts.base')
@section('title', 'Terms and Conditions · Melai Nuts')
@section('content')
<main class="center-page" style="align-items:flex-start">
<article class="card" style="max-width:760px;line-height:1.6">
    <h1>Terms and Conditions</h1>
    <p class="muted">Version {{ config('melai.legal.terms_version') }}</p>
    <section>
        <h2>1. What this app does</h2>
        <p>Melai Nuts lets you browse products, order from a Melai Nuts branch for delivery or pickup, track your orders, request refunds and earn loyalty points. Staff, owners and delivery riders use the same app for the shop counter, stock and deliveries.</p>
    </section>
    <section>
        <h2>2. Your account</h2>
        <p>Give your real name, a working email and a mobile number you own. Keep your password secret and do not share your account. You are responsible for what is done with your account. Tell a branch right away if you think someone else is using it. We may deactivate an account that breaks these terms.</p>
    </section>
    <section>
        <h2>3. Orders and payment</h2>
        <p>Prices, stock, delivery fees and discounts are checked by our system when you place the order; the total on your confirmation is the amount you pay. You pay in cash on delivery or in cash when you pick up at the counter. Online payment is offered only when the shop turns it on. An order may be cancelled if an item runs out; you are not charged for cancelled items.</p>
    </section>
    <section>
        <h2>4. Refunds</h2>
        <p>You can ask for a refund in the app, with a reason. The branch reviews each request. The refund amount is computed by the system from the items you return, not typed in by anyone. Approved refunds are paid back in cash at the branch or to the original payment method. The time limit for asking for a refund is set by Melai Nuts.</p>
        <p class="muted" style="color:#91571C">Draft wording — to be confirmed by Melai Nuts.</p>
    </section>
    <section>
        <h2>5. Loyalty points</h2>
        <p>You earn points when an order is completed. Points from an order that is refunded are taken back. Points have no cash value, cannot be transferred to another person and are used only for rewards in this app. Melai Nuts may change the earning and reward rules; changes are shown in the app before they apply.</p>
        <p class="muted" style="color:#91571C">Draft wording — to be confirmed by Melai Nuts.</p>
    </section>
    <section>
        <h2>6. Delivery</h2>
        <p>Delivery areas and fees are set by each branch and shown before you order. Please be at the delivery address and keep your phone on. While your order is out for delivery you can follow the rider on a map. The rider may take a photo of the delivered parcel as proof of delivery.</p>
    </section>
    <section>
        <h2>7. Acceptable use</h2>
        <p>Do not place orders you do not mean to pay for or collect, guess voucher codes, copy the catalog with automated tools, try to get around the app&#x27;s security, or use another person&#x27;s account. The app limits repeated attempts to protect every customer.</p>
    </section>
    <section>
        <h2>8. Changes to these terms</h2>
        <p>When these terms or the Privacy Policy change, the app shows the new version and asks you to accept it again before you continue.</p>
    </section>
    <section>
        <h2>9. Contact</h2>
        <p>For questions about your account, an order or these terms, contact any Melai Nuts branch. Branch phone numbers are listed in the app under Settings &gt; Branch Settings.</p>
    </section>
    <p><a class="link" href="{{ url()->previous() }}">Go back</a> · <a class="link" href="{{ route('legal.privacy') }}">Privacy Policy</a></p>
</article>
</main>
@endsection
