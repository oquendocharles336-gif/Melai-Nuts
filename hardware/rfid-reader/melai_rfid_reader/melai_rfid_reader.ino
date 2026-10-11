/*
 * Melai Nuts — Golden Kernel Club RFID card reader
 * Arduino + MFRC522 (RC522, 13.56 MHz MIFARE cards / key fobs)
 *
 * Two output modes (pick one below):
 *
 *   MODE_SERIAL   (Arduino Uno / Nano / Mega)
 *       Prints one line per tap over USB serial at 9600 baud:  UID:04A1B2C3
 *       The admin website reads it with "Connect USB reader" (Chrome / Edge, Web Serial).
 *
 *   MODE_KEYBOARD (Arduino Leonardo / Pro Micro / Micro — ATmega32U4 boards only)
 *       The board acts as a USB keyboard and TYPES the UID followed by Enter into
 *       whatever text box has focus. Works with the Flutter POS app on an Android
 *       tablet (USB-OTG cable) or Windows, and with the admin website's "Tap card" box.
 *
 * Only the card's UID is sent. The UID is not a secret or a password: the server only
 * accepts it from a signed-in staff member and stores just its SHA-256 hash.
 *
 * Library: "MFRC522" by GithubCommunity (Arduino IDE > Tools > Manage Libraries).
 *
 * Wiring (RC522 runs on 3.3 V — NOT 5 V):
 *
 *   RC522 pin   Uno / Nano     Leonardo / Pro Micro
 *   ---------   ----------     --------------------
 *   SDA (SS)    D10            D10
 *   SCK         D13            D15 (Pro Micro) / ICSP-3 (Leonardo)
 *   MOSI        D11            D16 (Pro Micro) / ICSP-4 (Leonardo)
 *   MISO        D12            D14 (Pro Micro) / ICSP-1 (Leonardo)
 *   RST         D9             D9
 *   3.3V        3.3V           3.3V (Pro Micro 5V boards: use a 3.3 V regulator)
 *   GND         GND            GND
 *   (optional)  buzzer + on D6, LED (with 220 Ω) on D5
 */

#include <SPI.h>
#include <MFRC522.h>

// ---------------- settings -------------------------------------------------
#define MODE_SERIAL            // change to MODE_KEYBOARD for Leonardo / Pro Micro
// #define MODE_KEYBOARD

const uint8_t PIN_SS = 10;
const uint8_t PIN_RST = 9;
const uint8_t PIN_BUZZER = 6;    // set to 255 if not connected
const uint8_t PIN_LED = 5;       // set to 255 if not connected
const unsigned long SAME_CARD_PAUSE_MS = 1500;  // ignore the same card held on the reader
// ---------------------------------------------------------------------------

#if defined(MODE_KEYBOARD)
  #if !defined(USBCON)
    #error "MODE_KEYBOARD needs an ATmega32U4 board (Leonardo, Micro, Pro Micro). Use MODE_SERIAL on Uno/Nano."
  #endif
  #include <Keyboard.h>
#endif

MFRC522 rfid(PIN_SS, PIN_RST);
String lastUid = "";
unsigned long lastAt = 0;

void beep(int ms) {
  if (PIN_LED != 255) digitalWrite(PIN_LED, HIGH);
  if (PIN_BUZZER != 255) tone(PIN_BUZZER, 2200, ms);
  delay(ms);
  if (PIN_LED != 255) digitalWrite(PIN_LED, LOW);
}

String readUid() {
  String uid = "";
  for (byte i = 0; i < rfid.uid.size; i++) {
    if (rfid.uid.uidByte[i] < 0x10) uid += "0";
    uid += String(rfid.uid.uidByte[i], HEX);
  }
  uid.toUpperCase();
  return uid;   // 8, 14 or 20 hex digits (4, 7 or 10 byte UID)
}

void setup() {
  if (PIN_LED != 255) pinMode(PIN_LED, OUTPUT);
  Serial.begin(9600);
  SPI.begin();
  rfid.PCD_Init();
  delay(50);
#if defined(MODE_KEYBOARD)
  Keyboard.begin();
#endif
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  if (v == 0x00 || v == 0xFF) {
    Serial.println("ERROR: RC522 not found - check the wiring and 3.3V power");
    for (int i = 0; i < 3; i++) { beep(80); delay(120); }
  } else {
    Serial.println("MELAI-RFID v1");
    beep(60);
  }
}

void loop() {
  // The website can ask "who are you?" to confirm the right device is connected.
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd == "PING") Serial.println("MELAI-RFID v1");
  }

  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) return;

  String uid = readUid();
  unsigned long now = millis();
  if (uid == lastUid && now - lastAt < SAME_CARD_PAUSE_MS) {
    lastAt = now;           // still on the reader: do not send it again
  } else {
    lastUid = uid;
    lastAt = now;
#if defined(MODE_KEYBOARD)
    Keyboard.print(uid);
    Keyboard.write(KEY_RETURN);
#else
    Serial.print("UID:");
    Serial.println(uid);
#endif
    beep(90);
  }

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}
