/*
 * Melai Nuts — Golden Kernel Club Wi-Fi card reader
 * ESP32 + MFRC522 (RC522, 13.56 MHz MIFARE cards / key fobs). No OLED.
 *
 * What it does
 *   Reads the UID of a tapped card and sends it over HTTPS (Wi-Fi) to the Supabase
 *   Edge Function "rfid-device-tap", signed with THIS reader's device code + key.
 *   The server decides everything:
 *     - a customer pressed "Link my card" in the app for this reader  -> card linked
 *     - the card is already linked                                    -> points synced
 *     - the card belongs to another account / is blocked              -> refused
 *   This sketch never holds the Supabase service-role key or any customer data.
 *
 * Libraries (Arduino IDE > Tools > Manage Libraries)
 *   - "MFRC522" by GithubCommunity            (tested API: 1.4.x)
 *   - "ArduinoJson" by Benoit Blanchon         (version 7.x)
 *   - WiFi, HTTPClient, WiFiClientSecure, SPI  come with the ESP32 board package
 * Board package
 *   Tools > Board > Boards Manager > "esp32" by Espressif Systems (3.x or 4.x).
 *   Board: "ESP32 Dev Module" (or your exact board). Serial Monitor: 115200 baud.
 *
 * Wiring (RC522 runs on 3.3 V — NEVER 5 V)
 *   RC522 SDA/SS -> GPIO 5      RC522 SCK  -> GPIO 18
 *   RC522 MOSI   -> GPIO 23     RC522 MISO -> GPIO 19
 *   RC522 RST    -> GPIO 4      RC522 IRQ  -> not connected
 *   RC522 3.3V   -> 3V3         RC522 GND  -> GND
 *   Feedback: onboard LED (GPIO 2 on most ESP32 DevKit boards).
 *   Optional buzzer: + to BUZZER_PIN below, - to GND (set BUZZER_PIN to -1 if none).
 *
 * Feedback
 *   1 long flash + 2 beeps ....... card LINKED to the account
 *   1 short flash + 1 beep ....... points SYNCED / already linked
 *   3 quick flashes + long beep .. card refused (not linked, other account, blocked)
 *   6 very quick flashes ......... reader problem (wrong key, server down, too many taps)
 *   slow blink (1 s) ............. no Wi-Fi (reconnecting)
 *   LED off ...................... ready, waiting for a card
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <SPI.h>
#include <MFRC522.h>
#include <ArduinoJson.h>
#include <time.h>

// =============================================================================
// ======================  CONFIG — EDIT THESE VALUES  =========================
// =============================================================================
// Wi-Fi (2.4 GHz only; the ESP32 cannot join 5 GHz networks)
const char *WIFI_SSID     = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

// https://<project-ref>.supabase.co/functions/v1/rfid-device-tap
const char *ENDPOINT_URL  = "https://YOUR-PROJECT-REF.supabase.co/functions/v1/rfid-device-tap";

// From:  select public.rfid_register_device('Counter 1', '<branch uuid>');   (SQL editor)
const char *DEVICE_ID     = "MN-RDR-XXXXXXXX";
const char *DEVICE_KEY    = "PASTE_THE_64_CHARACTER_DEVICE_KEY_HERE";

// HTTPS server check.
//  - ESP32 board package 4.x: the built-in Mozilla root bundle is used; leave ROOT_CA_PEM empty.
//  - ESP32 board package 3.x: paste the ROOT certificate of your Supabase URL here (PEM, see README).
const char *ROOT_CA_PEM = "";
// Bench testing ONLY: true = encrypt but do NOT check the server certificate.
// Leave false for a reader at the counter.
const bool ALLOW_INSECURE_TLS = false;

// Pins (your wiring)
const int PIN_RC522_SS   = 5;
const int PIN_RC522_RST  = 4;
const int PIN_SPI_SCK    = 18;
const int PIN_SPI_MISO   = 19;
const int PIN_SPI_MOSI   = 23;
const int LED_PIN        = 2;     // onboard LED; -1 = none
const bool LED_ACTIVE_HIGH = true; // false if your board's LED lights on LOW
const int BUZZER_PIN     = -1;    // e.g. 25; -1 = no buzzer
const bool BUZZER_IS_ACTIVE = true; // true: active buzzer (on/off); false: passive (tone)

// Timing
const unsigned long HTTP_TIMEOUT_MS      = 8000;   // one request
const int           HTTP_MAX_ATTEMPTS    = 3;      // network errors / 5xx only
const unsigned long SAME_CARD_PAUSE_MS   = 3000;   // ignore the same card for this long
const unsigned long WIFI_RETRY_MS        = 5000;   // between reconnect attempts
const unsigned long READER_CHECK_MS      = 5000;   // RC522 health check
// =============================================================================

MFRC522 rfid(PIN_RC522_SS, PIN_RC522_RST);

String lastUid = "";
unsigned long lastUidAt = 0;
unsigned long lastWifiTry = 0;
unsigned long lastReaderCheck = 0;
unsigned long lastBlink = 0;
bool blinkState = false;
bool readerOk = false;
bool wifiWasUp = false;
bool timeSynced = false;

// ---------------------------------------------------------------- feedback ---
void led(bool on) {
  if (LED_PIN < 0) return;
  digitalWrite(LED_PIN, (on == LED_ACTIVE_HIGH) ? HIGH : LOW);
}

void buzz(bool on, unsigned int ms) {
  if (BUZZER_PIN < 0) return;
  if (BUZZER_IS_ACTIVE) {
    digitalWrite(BUZZER_PIN, on ? HIGH : LOW);
  } else if (on) {
    tone(BUZZER_PIN, 2200, ms);
  } else {
    noTone(BUZZER_PIN);
  }
}

void pulse(unsigned int onMs, unsigned int offMs, int times, bool withBeep) {
  for (int i = 0; i < times; i++) {
    led(true);
    if (withBeep) buzz(true, onMs);
    delay(onMs);
    led(false);
    if (withBeep) buzz(false, 0);
    delay(offMs);
  }
}

void feedbackLinked()  { led(true); buzz(true, 120); delay(120); buzz(false, 0); delay(80);
                         buzz(true, 120); delay(120); buzz(false, 0); delay(760); led(false); }
void feedbackSynced()  { pulse(250, 50, 1, true); }
void feedbackRefused() { pulse(90, 90, 3, false); led(true); buzz(true, 600); delay(600); buzz(false, 0); led(false); }
void feedbackProblem() { pulse(50, 60, 6, false); }

// ------------------------------------------------------------------- Wi-Fi ---
bool wifiUp() { return WiFi.status() == WL_CONNECTED; }

void startWifi() {
  Serial.printf("[wifi] connecting to \"%s\" ...\n", WIFI_SSID);
  WiFi.disconnect(true, false);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  lastWifiTry = millis();
}

void syncClock() {
  // A correct clock lets TLS check the certificate dates.
  configTime(8 * 3600, 0, "pool.ntp.org", "time.google.com");
  Serial.print("[time] syncing");
  struct tm t;
  for (int i = 0; i < 20; i++) {
    if (getLocalTime(&t, 500) && t.tm_year > (2024 - 1900)) {
      Serial.printf(" ok: %04d-%02d-%02d %02d:%02d (UTC+8)\n", t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min);
      timeSynced = true;
      return;
    }
    Serial.print(".");
  }
  Serial.println(" failed (will retry on next reconnect)");
}

// Called every loop: reports changes, reconnects, blinks slowly while down.
void keepWifi() {
  if (wifiUp()) {
    if (!wifiWasUp) {
      wifiWasUp = true;
      led(false);
      Serial.printf("[wifi] connected. IP %s  RSSI %d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
      if (!timeSynced) syncClock();
    }
    return;
  }
  if (wifiWasUp) {
    wifiWasUp = false;
    Serial.println("[wifi] connection lost");
  }
  if (millis() - lastBlink >= 1000) {
    lastBlink = millis();
    blinkState = !blinkState;
    led(blinkState);
  }
  if (millis() - lastWifiTry >= WIFI_RETRY_MS) {
    Serial.printf("[wifi] still offline (status %d), retrying\n", (int)WiFi.status());
    startWifi();
  }
}

// ------------------------------------------------------------------- RC522 ---
bool readerAlive() {
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  return !(v == 0x00 || v == 0xFF);
}

void initReader() {
  rfid.PCD_Init();
  delay(10);
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  readerOk = !(v == 0x00 || v == 0xFF);
  if (readerOk) {
    Serial.printf("[rc522] ready (firmware 0x%02X)\n", v);
  } else {
    Serial.println("[rc522] NOT FOUND - check wiring (SDA 5, SCK 18, MOSI 23, MISO 19, RST 4, 3V3, GND)");
  }
}

void checkReader() {
  if (millis() - lastReaderCheck < READER_CHECK_MS) return;
  lastReaderCheck = millis();
  bool alive = readerAlive();
  if (!alive) {
    if (readerOk) Serial.println("[rc522] stopped answering, re-initialising");
    readerOk = false;
    initReader();
  } else if (!readerOk) {
    readerOk = true;
    Serial.println("[rc522] answering again");
  }
}

String uidHex(const MFRC522::Uid &uid) {
  String s;
  for (byte i = 0; i < uid.size; i++) {
    if (uid.uidByte[i] < 0x10) s += '0';
    s += String(uid.uidByte[i], HEX);
  }
  s.toUpperCase();
  return s;
}

// -------------------------------------------------------------------- HTTP ---
struct TapReply {
  int http = 0;          // HTTP status, or <0 for a network error
  String result;         // linked | already_linked | synced | ... | error
  String message;
  long points = -1;      // -1 = not sent
  String label;
};

TapReply postOnce(const String &uid) {
  TapReply r;
  WiFiClientSecure client;
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 4
  if (ALLOW_INSECURE_TLS) client.setInsecure();
  else if (strlen(ROOT_CA_PEM) > 0) client.setCACert(ROOT_CA_PEM);
  else client.useBuiltinCACertBundle();
#else
  if (ALLOW_INSECURE_TLS) {
    client.setInsecure();
  } else if (strlen(ROOT_CA_PEM) > 0) {
    client.setCACert(ROOT_CA_PEM);
  } else {
    r.http = -100;
    r.result = "error";
    r.message = "ROOT_CA_PEM is empty (needed on ESP32 board package 3.x). See README.";
    return r;
  }
#endif
  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(client, ENDPOINT_URL)) {
    r.http = -101;
    r.result = "error";
    r.message = "Bad ENDPOINT_URL";
    return r;
  }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Device-Id", DEVICE_ID);
  http.addHeader("X-Device-Key", DEVICE_KEY);
  http.addHeader("User-Agent", "MelaiReaderESP32/1.0");

  JsonDocument req;
  req["card_uid"] = uid;
  String body;
  serializeJson(req, body);

  unsigned long t0 = millis();
  r.http = http.POST(body);
  unsigned long took = millis() - t0;
  if (r.http <= 0) {
    r.result = "error";
    r.message = http.errorToString(r.http);
    Serial.printf("[http] network error %d (%s) after %lu ms\n", r.http, r.message.c_str(), took);
    http.end();
    return r;
  }
  String payload = http.getString();
  http.end();
  Serial.printf("[http] %d in %lu ms: %s\n", r.http, took, payload.c_str());

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) {
    r.result = "error";
    r.message = String("Unreadable reply: ") + err.c_str();
    return r;
  }
  r.result = doc["result"] | "error";
  r.message = doc["message"] | "";
  if (!doc["points_balance"].isNull()) r.points = doc["points_balance"].as<long>();
  r.label = doc["card_label"] | "";
  return r;
}

// Retries network errors and 5xx (the server answers a repeated tap the same way).
TapReply postTap(const String &uid) {
  TapReply r;
  for (int attempt = 1; attempt <= HTTP_MAX_ATTEMPTS; attempt++) {
    if (!wifiUp()) {
      r.http = -1;
      r.result = "error";
      r.message = "No Wi-Fi";
      Serial.println("[http] no Wi-Fi, request not sent");
      return r;
    }
    Serial.printf("[http] POST attempt %d/%d\n", attempt, HTTP_MAX_ATTEMPTS);
    r = postOnce(uid);
    bool retryable = (r.http <= 0 && r.http > -100) || r.http >= 500;
    if (!retryable) return r;
    if (attempt < HTTP_MAX_ATTEMPTS) delay(attempt * 700);
  }
  return r;
}

// -------------------------------------------------------------------- main ---
void handleCard(const String &uid) {
  Serial.println();
  Serial.printf("[card] UID %s\n", uid.c_str());
  led(true);
  TapReply r = postTap(uid);
  led(false);

  Serial.printf("[result] %s", r.result.c_str());
  if (r.label.length()) Serial.printf("  card %s", r.label.c_str());
  if (r.points >= 0) Serial.printf("  balance %ld pts", r.points);
  Serial.println();
  if (r.message.length()) Serial.printf("[result] %s\n", r.message.c_str());

  if (r.result == "linked") {
    feedbackLinked();
  } else if (r.result == "synced" || r.result == "already_linked") {
    feedbackSynced();
  } else if (r.result == "unregistered" || r.result == "card_taken" || r.result == "card_blocked" ||
             r.result == "customer_has_card" || r.result == "invalid_card") {
    feedbackRefused();
  } else {
    if (r.result == "device_rejected") Serial.println("[hint] check DEVICE_ID / DEVICE_KEY, or the reader is switched off");
    if (r.result == "rate_limited") Serial.println("[hint] too many requests; wait a minute");
    feedbackProblem();
  }
}

void printStatus() {
  Serial.println("---- status ----");
  Serial.printf("device   %s\n", DEVICE_ID);
  Serial.printf("wifi     %s", wifiUp() ? "connected" : "offline");
  if (wifiUp()) Serial.printf(" (%s, %d dBm)", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  Serial.println();
  Serial.printf("rc522    %s\n", readerOk ? "ok" : "not answering");
  Serial.printf("clock    %s\n", timeSynced ? "synced" : "not synced");
  Serial.printf("endpoint %s\n", ENDPOINT_URL);
  Serial.println("----------------");
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== Melai Nuts RFID reader (ESP32) v1.0 ===");
  if (LED_PIN >= 0) pinMode(LED_PIN, OUTPUT);
  if (BUZZER_PIN >= 0) pinMode(BUZZER_PIN, OUTPUT);
  led(false);
  buzz(false, 0);

  if (String(DEVICE_ID).indexOf("XXXX") >= 0 || String(DEVICE_KEY).startsWith("PASTE")) {
    Serial.println("[config] DEVICE_ID / DEVICE_KEY are not set. Edit the CONFIG section and upload again.");
  }
  if (ALLOW_INSECURE_TLS) Serial.println("[config] WARNING: ALLOW_INSECURE_TLS is on (server certificate NOT checked)");

  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, PIN_RC522_SS);
  initReader();
  startWifi();
  Serial.println("Type 's' + Enter in the Serial Monitor for status.");
}

void loop() {
  keepWifi();
  checkReader();

  if (Serial.available()) {
    char c = Serial.read();
    if (c == 's' || c == 'S') printStatus();
  }

  if (!readerOk) { delay(50); return; }
  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) { delay(20); return; }

  String uid = uidHex(rfid.uid);
  // Stop talking to this card: a card left on the reader is not read again.
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();

  if (uid.length() < 8) {
    Serial.printf("[card] UID too short (%s), ignored\n", uid.c_str());
    feedbackRefused();
    return;
  }
  if (uid == lastUid && millis() - lastUidAt < SAME_CARD_PAUSE_MS) {
    return;   // the same tap seen twice
  }
  lastUid = uid;
  lastUidAt = millis();

  if (!wifiUp()) {
    Serial.printf("[card] UID %s read, but there is no Wi-Fi. Tap again when connected.\n", uid.c_str());
    feedbackProblem();
    return;
  }
  handleCard(uid);
  lastUidAt = millis();   // the pause counts from the end of the request
}
