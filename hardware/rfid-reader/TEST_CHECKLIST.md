# RFID reader — test checklist (do this on the real hardware before going live)

Tick each line on the actual reader, the actual cards and the actual POS tablet / PC.
Write down the board (Uno / Nano / Pro Micro), the RC522 module and the date.

## A. Wiring and power
- [ ] RC522 is powered from **3.3 V** (measure it: 3.2–3.4 V). Never 5 V.
- [ ] Serial Monitor (9600) shows `MELAI-RFID v1` after reset. With the RC522 unplugged it shows
      `ERROR: RC522 not found` and beeps three times.
- [ ] Unplug the RC522's SDA wire while running, plug it back: within ~5 s the monitor shows
      `ERROR: RC522 not responding - restarting it`, then `MELAI-RFID v1` again (self-healing check).
- [ ] Optional buzzer / LED: one short beep + blink per tap. If you use a *passive* buzzer, set
      `BUZZER_IS_ACTIVE = false`.

## B. Reading cards
- [ ] Each test card prints `UID:` + 8 hex digits (4-byte cards) / 14 (7-byte) — always upper case.
- [ ] Holding a card on the reader for 10 s sends it **once**.
- [ ] Tapping the same card again after lifting it sends it again.
- [ ] Two different cards tapped quickly are both sent.
- [ ] Read distance: works through a wallet / card sleeve at ≤ 2 cm; note the distance.
- [ ] 50 taps in a row: 50 lines, none garbled.

## C. Admin website (serial mode)
- [ ] Chrome or Edge on `https://` (or `http://localhost`): Loyalty Cards > **Connect USB reader** lists the Arduino.
- [ ] Tap a linked card: the page shows the customer. Tap an unknown card: "not registered".
- [ ] Blocked card: shows blocked, cannot be used for a sale.
- [ ] Unplug the USB cable while connected: the page says the reader disconnected; reconnect works.
- [ ] **Manual fallback:** type the card number (UID or the printed `GK-` label) into **Tap card here**
      and press Enter — same result as a tap.

## D. POS app (keyboard mode, Pro Micro over USB-OTG)
- [ ] With the *Find loyalty customer* field focused, a tap types the UID and Enter, and the customer
      is attached to the sale.
- [ ] Tapping while another field (e.g. cash received) is focused does **not** corrupt that field in a
      harmful way (check what happens, train staff to focus the lookup first).
- [ ] **Manual fallback:** reader unplugged — type the phone, e-mail or the printed `GK-` label in the
      same field: the customer is found.
- [ ] *Link RFID card*: tapping a new card links it; tapping a card already linked to someone else is refused.

## E. Card life cycle (any branch)
- [ ] Block a card at branch A → tapping it at branch B is refused immediately.
- [ ] Replace a card: the new card works, the old one is refused, the points stay on the account.
- [ ] Owner can unblock a found card (not one already replaced).

## F. Record
| Date | Board | Module | Result | Notes |
|---|---|---|---|---|
| | | | | |

The sketch was reviewed but could not be compiled or run in the build environment (no Arduino
toolchain download possible there). Compile it in the Arduino IDE with the MFRC522 library first.
