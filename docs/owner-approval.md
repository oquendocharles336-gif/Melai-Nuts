# For the owner: approve or decide

**Status (2026-11-07): sections 1 and 2 approved as written, with these answers. The wording is in the app and on the admin website (Terms and Privacy version `2026-11-07`).**

- Business name: Melai Nuts Retailing
- Data Protection Officer: the owner of Melai Nuts Retailing, melaioraya5@gmail.com
- Kept for: orders, payments and refunds 5 years (tax and accounting). Account details deleted within 30 days of a deletion request, except records the law requires
- Deletion requests and privacy questions: melaioraya5@gmail.com
- Refund time limit: 7 days after pickup
- Customer cancels: downpayment refunded (current behaviour). Only a no-show keeps it

Still open: how many days' notice before loyalty rule changes (Terms 5), and the HitPay live steps (section 4).

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
