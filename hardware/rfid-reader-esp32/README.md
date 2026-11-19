# Golden Kernel Club Wi-Fi card reader (ESP32 + RC522)

A counter reader that needs no USB connection to the POS. It reads a loyalty card's UID and
posts it over HTTPS to the `rfid-device-tap` Edge Function. Customers use it to **link their own
card** ("Link my card" in the app); a linked card tapped again **syncs the points** shown in the app.
The USB reader in `../rfid-reader/` still works for staff linking at the POS / admin website.

Sketch: `melai_rfid_reader_esp32/melai_rfid_reader_esp32.ino` (single file).

## 1. Wiring (no OLED)

| RC522 | ESP32 |
|---|---|
| SDA / SS | GPIO 5 |
| SCK | GPIO 18 |
| MOSI | GPIO 23 |
| MISO | GPIO 19 |
| RST | GPIO 4 |
| 3.3V | 3V3 (**never 5 V**) |
| GND | GND |
| IRQ | not connected |

Feedback uses the onboard LED (GPIO 2 on most DevKit boards). Optional buzzer: `+` to a free GPIO
(e.g. 25) and `-` to GND, then set `BUZZER_PIN` in the sketch.

## 2. Arduino IDE setup

1. *File → Preferences → Additional boards manager URLs*:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
2. *Tools → Board → Boards Manager* → install **esp32 by Espressif Systems** (3.x or 4.x).
3. *Tools → Manage Libraries* → install **MFRC522** (GithubCommunity) and **ArduinoJson** (Benoit Blanchon, 7.x).
   `WiFi`, `WiFiClientSecure`, `HTTPClient` and `SPI` come with the board package.
4. Board: **ESP32 Dev Module** (or yours). Port: the board's COM port.

## 3. Create the reader in Supabase (once per reader)

Supabase Dashboard → SQL Editor (runs as the database owner):

```sql
-- list branch ids
select id, name from public.branches order by name;

-- create the reader; copy device_code and device_key from the result (the key is shown ONCE)
select public.rfid_register_device('Counter 1', '<branch uuid>');
```

Other commands:

```sql
select public.rfid_rotate_device_key('MN-RDR-XXXXXXXX');          -- new key (old one stops working)
select public.rfid_set_device_active('MN-RDR-XXXXXXXX', false);   -- switch a reader off (lost / stolen)
select * from public.rfid_device_taps order by created_at desc limit 50;   -- audit log
```

## 4. Deploy the Edge Function (once)

```bash
supabase db push                                   # or run the new migration in the SQL editor
supabase functions deploy rfid-device-tap --no-verify-jwt
```

No extra secrets: `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided by Supabase to the
function. The reader never has the service-role key.

## 5. Configure and upload the sketch

Edit the **CONFIG** block at the top of the `.ino`:

| Setting | Value |
|---|---|
| `WIFI_SSID` / `WIFI_PASSWORD` | the shop's **2.4 GHz** Wi-Fi |
| `ENDPOINT_URL` | `https://<project-ref>.supabase.co/functions/v1/rfid-device-tap` |
| `DEVICE_ID` / `DEVICE_KEY` | from step 3 |
| `ROOT_CA_PEM` | board package **4.x**: leave empty (built-in root bundle). **3.x**: paste the root certificate (below) |

Getting `ROOT_CA_PEM` (board package 3.x): open your `ENDPOINT_URL` host in Chrome → padlock →
*Connection is secure → Certificate is valid → Details* → select the **top (root)** certificate →
*Export* (Base-64 PEM). Or: `openssl s_client -connect <project-ref>.supabase.co:443 -showcerts`
and take the last certificate. Paste it as a C string with `\n` line endings:

```cpp
const char *ROOT_CA_PEM =
  "-----BEGIN CERTIFICATE-----\n"
  "MIIF...\n"
  "-----END CERTIFICATE-----\n";
```

`ALLOW_INSECURE_TLS = true` skips the certificate check — only for a bench test, never at the counter.

Upload, then open *Tools → Serial Monitor* at **115200** baud. Type `s` + Enter for a status line.

## 6. What you should see

```
=== Melai Nuts RFID reader (ESP32) v1.0 ===
[rc522] ready (firmware 0x92)
[wifi] connected. IP 192.168.1.40  RSSI -58 dBm
[time] syncing.. ok: 2026-11-19 14:02 (UTC+8)

[card] UID 04A1B2C3
[http] POST attempt 1/3
[http] 200 in 640 ms: {"result":"linked","message":"Card linked.","points_balance":120,"card_label":"GK-3F9A-71C2"}
[result] linked  card GK-3F9A-71C2  balance 120 pts
```

| Signal | Meaning |
|---|---|
| 1 long flash + 2 beeps | **linked** to the account whose "Link my card" is open on this reader |
| 1 short flash + 1 beep | **synced** (linked card) / already linked |
| 3 quick flashes + long beep | refused: not linked yet, belongs to another account, blocked / removed, or the account already has a card |
| 6 very quick flashes | reader problem: wrong device key, reader switched off, server down, too many taps |
| slow 1 s blink | no Wi-Fi (it keeps reconnecting) |

## 7. Customer flow

1. App → **Golden Kernel Club card** → pick this reader → **Link my card** (60-second window).
2. Tap the card on the reader. The app shows "Card linked" and the points within a second (realtime).
3. Later taps on any reader only sync the points; nothing is registered twice.
4. Lost card: app → **Block card** (stops at once; points stay). **Remove card** retires it for good.

## Limits and safety

- One open link session per reader; a second customer is told to wait. Sessions last 60 s.
- 30 taps per reader per minute; 20 wrong-key requests in 10 minutes blocks that device code for
  the rest of the window. Every request (including refused ones) is in `rfid_device_taps`.
- The card UID is a lookup key, not a password. Redeeming points at the counter needs the staff
  member to confirm the customer's name, and the customer's loyalty PIN when they set one.
- The sketch was **not compiled or run on a board** in the build environment. Check it with
  *Sketch → Verify* first.
