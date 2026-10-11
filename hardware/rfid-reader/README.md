# Golden Kernel Club RFID reader (Arduino + RC522)

A small USB card reader for the counter. It reads the loyalty card's UID and sends it to
the POS (Flutter app) or to the admin website. Everything else — who owns the card, whether
it is blocked, points — is decided by the database (`supabase/migrations/20261011000000_loyalty_cards.sql`).

## Parts (about ₱400–₱700)
| Part | Notes |
|---|---|
| Arduino **Uno / Nano** (serial mode) **or Leonardo / Pro Micro** (keyboard mode) | Pro Micro is best for an Android POS tablet |
| RC522 RFID module (13.56 MHz) | usually comes with 1 card + 1 key fob |
| MIFARE Classic 1K cards / fobs | the loyalty cards |
| Jumper wires, USB cable (USB-OTG adapter for a tablet) | |
| Optional: active buzzer, LED + 220 Ω resistor | beep / blink on each tap |

Wiring is in the comment at the top of `melai_rfid_reader/melai_rfid_reader.ino`.
**Power the RC522 from 3.3 V, never 5 V.**

## Flash it
1. Arduino IDE → *Tools → Manage Libraries* → install **MFRC522** (GithubCommunity).
2. Open `melai_rfid_reader/melai_rfid_reader.ino`.
3. Uno/Nano: keep `#define MODE_SERIAL`. Leonardo/Pro Micro: switch to `#define MODE_KEYBOARD`.
4. Select the board and port, press **Upload**.
5. Serial mode check: *Tools → Serial Monitor*, 9600 baud. You should see `MELAI-RFID v1`,
   and `UID:XXXXXXXX` each time you tap a card.

## Use it
| Where | Mode | How |
|---|---|---|
| **Admin website → Loyalty Cards** | Serial | Chrome or Edge, press **Connect USB reader**, pick the Arduino. Tap a card: the page shows whose card it is. On a customer's page the tap fills in the card number for *Link* / *Replace*. |
| Admin website | Keyboard | Click the **Tap card here** box, tap the card. |
| **POS app (cashier) → Find loyalty customer** | Keyboard | Plug the Pro Micro into the tablet (USB-OTG). Open the lookup, tap the card: it types the UID + Enter and the customer is attached to the sale. |
| POS app → Link card | Keyboard | After finding the customer by phone/e-mail, press **Link RFID card** and tap a new card. |

Web Serial only works on `https://` or `http://localhost`.

## Card life cycle
- **Link**: staff find the customer (exact phone / e-mail), tap a new card. One active card per customer.
- **Block**: a customer reports the card lost → any staff blocks it; it stops working at all branches at once.
- **Replace**: tap a new card with a reason; the old card is retired for good. **Points stay** (they are on the customer's account, not the card).
- **Unblock**: owner only, if the card was found again (and not yet replaced).
- Every change is in the card history (append-only) and the staff audit log; the customer gets an app notification.

## Test without hardware
In the admin website's **Tap card here** box type any 8–20 hex digits (e.g. `04A1B2C3`) and press Enter —
that is exactly what a keyboard-mode reader does.

## Not tested here
This sketch was written against the MFRC522 library API but was **not** run on a physical
board in this environment. Test on the real reader before going live.
