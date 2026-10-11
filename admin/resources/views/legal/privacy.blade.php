{{-- GENERATED from lib/l10n/app_en.arb (privacyS*) so the website shows the same text as the app.
     TODO(owner): sections marked "Draft wording" need the owner's confirmation (see lib/core/config/legal_config.dart). --}}
@extends('layouts.base')
@section('title', 'Privacy Policy · Melai Nuts')
@section('content')
<main class="center-page" style="align-items:flex-start">
<article class="card" style="max-width:760px;line-height:1.6">
    <h1>Privacy Policy</h1>
    <p class="muted">Version {{ config('melai.legal.terms_version') }}</p>
    <section>
        <h2>1. Who is responsible for your data</h2>
        <p>Melai Nuts is the personal information controller for the data in this app, as defined by the Philippine Data Privacy Act of 2012 (Republic Act No. 10173).</p>
        <p class="muted" style="color:#91571C">Draft wording — to be confirmed by Melai Nuts.</p>
    </section>
    <section>
        <h2>2. Data we collect</h2>
        <ul><li>Your name, email address and mobile number.</li><li>Delivery addresses and the map pin you place.</li><li>Your orders, payments, refunds and loyalty points.</li><li>Your location, only while you use &quot;Use my location&quot; or, for riders, during an active delivery run.</li><li>Photos taken as proof of delivery.</li><li>A notification token so we can send order updates to this phone.</li><li>Crash reports, which carry an account ID but not your name, email or phone.</li></ul>
    </section>
    <section>
        <h2>3. How we use it</h2>
        <p>To create your account, prepare and deliver your orders, take payment, handle refunds, keep your loyalty points, send the updates you chose, keep the app secure, and fix problems. We do not sell your data.</p>
    </section>
    <section>
        <h2>4. Where it is stored and who can see it</h2>
        <p>Sign-in is handled by Firebase (Google). Business data is stored in our Supabase database. A copy of recent data is kept on your phone so the app works offline; it is erased when you sign out. Staff see only what their branch needs; a rider sees the name, phone and address for the deliveries assigned to them.</p>
    </section>
    <section>
        <h2>5. How long we keep it</h2>
        <p>We keep your account data while your account is active. Sales and payment records are kept for as long as Philippine tax and business rules require. The exact retention periods are set by Melai Nuts.</p>
        <p class="muted" style="color:#91571C">Draft wording — to be confirmed by Melai Nuts.</p>
    </section>
    <section>
        <h2>6. Your rights (RA 10173)</h2>
        <p>You have the right to be informed, to access your data, to object, to have it corrected, to have it erased or blocked, to data portability, to claim damages, and to file a complaint with the National Privacy Commission (privacy.gov.ph).</p>
    </section>
    <section>
        <h2>7. Deleting your data</h2>
        <p>To ask for a copy of your data or for your account to be deleted, contact any Melai Nuts branch. Records the law requires us to keep (for example, receipts) are kept but no longer linked to your profile where possible.</p>
        <p class="muted" style="color:#91571C">Draft wording — to be confirmed by Melai Nuts.</p>
    </section>
    <section>
        <h2>8. Permissions on your phone</h2>
        <p>The app asks for the camera (scan barcodes, proof-of-delivery photos), location (pin your address, riders&#x27; live delivery) and notifications (order updates) only when you use that feature. You can change them any time in Settings &gt; Permissions.</p>
    </section>
    <p><a class="link" href="{{ url()->previous() }}">Go back</a> · <a class="link" href="{{ route('legal.terms') }}">Terms and Conditions</a></p>
</article>
</main>
@endsection
