# For the owner: approve or decide

**Status (2026-11-07): sections 1 and 2 approved as written, with these answers. The wording is in the app and on the admin website (Terms and Privacy version `2026-11-07`).**

- Business name: Melai Nuts Retailing
- Data Protection Officer: the owner of Melai Nuts Retailing, melaioraya5@gmail.com
- Kept for: orders, payments and refunds 5 years (tax and accounting). Account details deleted within 30 days of a deletion request, except records the law requires
- Deletion requests and privacy questions: melaioraya5@gmail.com
- Refund time limit: 7 days after pickup
- Customer cancels: downpayment refunded (current behaviour). Only a no-show keeps it

Also approved by the owner (2026-11-07): Terms 5, 30 days' notice before loyalty rule changes; Terms 9, branch phone numbers are on the order details and checkout screens. The 7-day refund window is enforced by migration `20261107120000`; the owner types **7** in Business settings ("Customers can request a refund within (days after pickup)").

Still open: the HitPay live steps (section 4).

---

## 1. New Terms wording (pickup downpayment)

Melai Nuts is pickup only for now, so delivery wording is removed too.

### Section 1. What this app does: replace

**English**
> Melai Nuts lets you browse products, order from a Melai Nuts branch for pickup at the counter, track your orders, request refunds and earn loyalty points. Staff and owners use the same app for the shop counter and stock.

**Filipino**
> Sa Melai Nuts, makikita mo ang mga produkto, makaka-order ka sa isang branch ng Melai Nuts para kunin sa counter, masusubaybayan mo ang iyong order, makakahiling ng refund, at makakaipon ng loyalty points. Ginagamit din ng staff at may-ari ang parehong app para sa counter at stock.

### Section 3. Orders and payment: replace

**English**
> Prices, stock and discounts are checked by our system when you place the order; the total on your confirmation is the amount you pay. Orders are for pickup at the branch counter. When online payment is on, you pay a 30% downpayment online through HitPay (GCash, QR Ph or card) and the rest in cash when you pick up. When online payment is off, you pay the full amount in cash at pickup. An order may be cancelled if an item runs out; you are not charged for cancelled items.

**Filipino**
> Sinusuri ng aming sistema ang presyo, stock at diskwento kapag nag-order ka; ang total sa iyong kumpirmasyon ang babayaran mo. Ang mga order ay kinukuha sa counter ng branch. Kapag bukas ang online payment, magbabayad ka ng 30% na downpayment online sa HitPay (GCash, QR Ph o card) at ang natitira ay cash pagkuha mo. Kapag sarado ang online payment, buong halaga ang babayaran nang cash pagkuha mo. Maaaring makansela ang order kung maubos ang isang item; hindi ka sisingilin para sa nakanselang item.

### Section 6. Delivery → Pickup and downpayment: replace

**English**
> **6. Pickup and downpayment**
> - Pay the downpayment within 30 minutes of placing the order. If it is not paid in time, the order is cancelled and nothing is charged.
> - Pick up your order within 2 days after it is marked "Ready for Pickup". If you do not pick it up in time, the order is cancelled and **the shop keeps the downpayment**.
> - If the order is cancelled for any other reason, including by the shop, your downpayment is refunded in full to the payment method you used.
> - Pay the balance in cash at the counter when you pick up.

**Filipino**
> **6. Pagkuha ng order at downpayment**
> - Bayaran ang downpayment sa loob ng 30 minuto mula nang mag-order. Kung hindi nabayaran sa oras, makakansela ang order at walang sisingilin.
> - Kunin ang iyong order sa loob ng 2 araw mula nang ito ay maging "Ready for Pickup". Kung hindi mo ito nakuha sa oras, makakansela ang order at **hindi na ibabalik ang downpayment**.
> - Kung makansela ang order sa ibang dahilan, kasama na kung ang tindahan ang nagkansela, ibabalik nang buo ang iyong downpayment sa paraan ng pagbayad na ginamit mo.
> - Bayaran ang natitira nang cash sa counter pagkuha mo.

Sections 2, 4, 5, 7, 8 and 9 stay as they are (section 4 waits for the refund answer below).

---

## 2. Privacy Policy changes

### Section 2. Data we collect: replace two lines

| Now | New (English) | New (Filipino) |
| --- | --- | --- |
| Delivery addresses and the map pin you place. | *(remove: no delivery)* | *(alisin)* |
| Your location, only while you use "Use my location" or, for riders, during an active delivery run. | Your phone's location, used on your phone to choose the nearest open branch. We save only the branch, not your location. | Ang lokasyon ng iyong telepono, ginagamit sa telepono mo para piliin ang pinakamalapit na bukas na branch. Ang branch lang ang iniingatan namin, hindi ang iyong lokasyon. |
| Photos taken as proof of delivery. | *(remove: no delivery)* | *(alisin)* |

### Section 4. Where it is stored and who can see it: add one sentence

- **English:** "Online payments are handled by HitPay. We receive the payment status and amount, not your card or GCash details."
- **Filipino:** "Ang online na bayad ay hawak ng HitPay. Ang natatanggap lang namin ay ang status at halaga ng bayad, hindi ang detalye ng iyong card o GCash."

Also remove the rider sentence at the end of section 4.

### Section 8. Permissions on your phone: replace

- **English:** "The app asks for the camera (scan barcodes), location (find your nearest branch) and notifications (order updates) only when you use that feature. You can change them any time in Settings > Permissions."
- **Filipino:** "Hinihingi lang ng app ang camera (pag-scan ng barcode), lokasyon (paghanap ng pinakamalapit na branch) at notifications (update ng order) kapag ginagamit mo ang feature na iyon. Mababago mo ang mga ito anumang oras sa Settings > Permissions."

### Still waiting from before (please fill in)

| Section | What we need |
| --- | --- |
| Privacy 1 | Registered business name, and the Data Protection Officer's name and email |
| Privacy 5 | How long to keep account data after an account closes, and sales/payment records (BIR usually requires 10 years) |
| Privacy 7 | Where customers send a data or deletion request (email or branch) |
| Terms 5 | How many days' notice before loyalty rule changes |

---

## 3. Refund time limit (decide)

**How many days after pickup can a customer request a refund?**

Today there is no limit: a customer can ask for a refund on any completed order, however old.

- [ ] ____ days after pickup
- [ ] No limit (keep as now)

Your answer goes into Terms section 4.

---

## 4. HitPay live: steps to finish

Online payment stays **off** until all of these are done.

1. **Live account:** log in at https://dashboard.hit-pay.com. Finish business verification and confirm PHP is the currency.
2. **Payment methods:** turn on GCash, QR Ph and card.
3. **Send us 2 things** (privately, never in chat or email):
   - the live **API Key** (Developers > API Keys)
   - the **Salt** of a new webhook (Developers > Webhook Endpoints > add `https://<project>.supabase.co/functions/v1/hitpay-webhook`, events `payment_request.completed` and `payment_request.failed`)
4. **Approve sections 1 to 3 above.** We then put the new wording in the app and release the update. Customers accept the new Terms when they next open it.
5. **Business settings** (admin website), only after the update is out, fill in:
   - Cash on Counter Pickup downpayment: **percent**, amount **30**
   - Only for orders of at least: leave empty (all orders)
   - Cancel an unpaid order after: **30** minutes
   - Customers must pick up within: **2** days
6. Turn online payment **on**.
7. **Test payment:** place one small real order, pay the downpayment with GCash, and check it shows **Paid** in the app within a few seconds.
8. **Test refund:** cancel that test order from the shop side and check the downpayment comes back to the GCash account (admin website > Refunds > Send via HitPay).

If step 7 or 8 fails, turn online payment off again and tell us.

---

## Offline use (version `2026-11-18.2`): to approve

The staff app now works offline (see `CHANGED_FILES.txt`). The Terms and Privacy Policy were updated to say so. Everyone is asked to accept the new version the next time they open the app. The new wording is in `lib/l10n/app_en.arb` / `app_fil.arb` and on the website at `/terms#terms-10` and `/privacy#privacy-12`. It shows the "draft" note until you approve it (remove `terms.10` and `privacy.12` from `LegalConfig.ownerReviewSections`, then run `python3 scripts/gen_legal_pages.py`).

- **Terms 10. Using the app offline (new):** what works without a connection; offline changes are "Pending sync" and are final only when the server accepts them; the server may refuse one, and a staff member then retries or discards it; offline receipts carry a temporary OFFLINE-… number and the server's total is final; "Expired" removals only on or after the expiry date, recorded with the staff member and time.
- **Privacy 12. Working offline (new):** what a staff or owner phone keeps (inventory, up to 300 recent e-receipts with the customer's name and contact number when the order has them, local notifications, expired-batch IDs, unsent changes), why, where (the app's private storage only), and for how long (saved copies erased at sign-out; unsent changes stay, linked only to their account, until sent or discarded; accepted changes deleted within 14 days).
- **Privacy 2 and 4 (changed):** one added bullet about offline staff changes, and one sentence noting that the offline copy on staff phones includes receipts with customer details.

Please confirm: is keeping a customer's name and contact number on the e-receipts on staff phones acceptable? If not, the app can leave those two fields out of the stored receipts.

## No SMS check of the mobile number, product reviews (version `2026-11-19`): to approve

* **Terms 2**: the SMS code before the first order is gone. The first order is still paid online
  first (50% or the full amount).
* **Privacy 2**: product reviews (rating, comment, date; shown with first name + last initial);
  the first-order record keeps the mobile number on the account when it was paid.
* **Privacy 4**: Firebase SMS only for the optional Android phone log-in; Google reCAPTCHA removed
  (the website no longer sends codes to mobile numbers).
* **Privacy 11**: the reCAPTCHA sentence is gone.
* **Privacy 10**: rewritten. The number is only format-checked; a number that matches another
  customer with a paid order keeps the first-order prepayment on the new account.

## Online payment first on every order (DRAFT, not approved, not in the app yet)

**Status (2026-11-19): draft for the owner. Nothing below is in the app or on the website.** The
Terms the customers see (version `2026-11-19.2`) still say cash is available from the second
order. Once approved: put the wording in `lib/l10n/app_en.arb` / `app_fil.arb`, run
`python3 scripts/gen_legal_pages.py`, and bump `termsVersion` in `LegalConfig` and
`MELAI_TERMS_VERSION` in `admin/config/melai.php` so everyone accepts it again.

What changed (migration `20261119080000_online_first_every_order.sql`): every order with
something to pay is paid online first. Online Payment = 100% online before the branch prepares
it. Cash on Counter Pickup = the downpayment set on the admin website (50%) online first, the
rest in cash at pickup. No cash-only orders. While online payment is off, no orders are taken.
The first-order rule (50% or 100% online) is unchanged.

### Terms 2. Your account: replace one sentence

EN, now: "Your first order is paid online first (50% or the full amount); cash payment is
available from your next order."

> Your first order is paid online first (50% or the full amount). Every later order is also paid online first, in full or as a downpayment.

FIL:

> Babayaran muna online ang iyong unang order (50% o ang buong halaga). Babayaran din muna online ang bawat susunod na order, buo man o downpayment.

### Terms 3. Orders and payment: replace the "Later orders" bullet

EN, now: "Later orders: when online payment is on, you pay the downpayment shown at checkout
online and the rest in cash when you pick up. When online payment is off, you pay the full
amount in cash at pickup."

> - Later orders: choose Online Payment and pay 100% online through HitPay before the branch prepares your order, or choose Cash on Counter Pickup and pay the downpayment shown at checkout online first, then the rest in cash when you pick up. There are no orders paid only in cash. While online payment is unavailable, orders cannot be placed; please try again later.

FIL:

> - Mga susunod na order: piliin ang Online Payment at bayaran nang 100% online sa HitPay bago ihanda ng branch ang iyong order, o piliin ang Cash on Counter Pickup at bayaran muna online ang downpayment na nakasaad sa checkout, at ang natitira ay cash pagkuha mo. Walang order na cash lang ang bayad. Habang hindi available ang online payment, hindi makakapag-order; pakisubukan mamaya.

### Terms 6. Pickup, online payment and downpayment: replace the first bullet

EN, now: "Pay the online part of your order (first-order payment or downpayment) within the
time shown at checkout, ..."

> - Pay the online part of your order (an Online Payment order, a first-order payment or a downpayment) within the time shown at checkout, 30 minutes unless the shop sets another limit. If it is not paid in time, the order is cancelled and nothing is charged.

FIL:

> - Bayaran ang online na bahagi ng iyong order (order na Online Payment, bayad ng unang order o downpayment) sa loob ng oras na nakasaad sa checkout, 30 minuto maliban kung iba ang itinakda ng tindahan. Kung hindi nabayaran sa oras, makakansela ang order at walang sisingilin.

The other Terms 6 bullets stay as they are. Note: the "pick up within 2 days or the shop keeps
the downpayment" rule applies to Cash on Counter Pickup downpayments only. An Online Payment
order (paid 100%) that is not picked up is not forfeited automatically.

Please confirm:
1. The wording above (EN and FIL).
2. That an unclaimed Online Payment order (paid 100%) should NOT be kept automatically, as now.

## Loyalty PIN for every use of points (DRAFT, not approved, not in the app yet)

Since migration 20261120020000, a customer who set a loyalty PIN must enter it whenever their
points are used: at the counter (as before), and now also for points on an app or website
order and for rewards in the app. Customers without a PIN see no change. The app and website
still show the approved wording until the owner approves this change.

### Terms 11. Loyalty cards: replace the PIN bullet

EN, now: "If you set a loyalty PIN, points can be used at the counter only with that PIN.
After 5 wrong tries, the PIN is locked for 15 minutes."

> - If you set a loyalty PIN, your points can be used only with that PIN: at the counter, on an order in the app or on the website, and for rewards. After 5 wrong tries, the PIN is locked for 15 minutes.

FIL, now: "Kung naglagay ka ng loyalty PIN, magagamit lang ang points sa counter gamit ang PIN
na iyon. Pagkatapos ng 5 maling subok, naka-lock ang PIN nang 15 minuto."

> - Kung naglagay ka ng loyalty PIN, magagamit lang ang iyong points gamit ang PIN na iyon: sa counter, sa order sa app o sa website, at para sa rewards. Pagkatapos ng 5 maling subok, naka-lock ang PIN nang 15 minuto.

Please confirm the wording above (EN and FIL).
