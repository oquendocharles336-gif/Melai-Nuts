/*
 * Melai Nuts — RFID card reader bridge for the admin website.
 *
 * Works with the Arduino sketch in hardware/rfid-reader/ in either mode:
 *   1. USB serial (Arduino Uno / Nano + RC522): the board prints "UID:04A1B2C3" lines.
 *      The browser reads them with the Web Serial API (Chrome or Edge, https or localhost).
 *   2. Keyboard mode (Arduino Leonardo / Pro Micro + RC522, or any USB "keyboard" RFID
 *      reader): the board types the UID and presses Enter into the focused "Tap card" box.
 *
 * Usage:  MelaiRfid.attach(rootElement, function (uid) { ... })
 * rootElement must contain [data-rfid-connect], [data-rfid-status] and [data-rfid-input].
 */
(function () {
  'use strict';

  var UID_RE = /^[0-9A-F]{8,20}$/;
  var DEBOUNCE_MS = 1500;

  function normalise(raw) {
    var v = String(raw || '').toUpperCase().replace(/^UID:/, '').replace(/[\s:\-.]/g, '');
    return UID_RE.test(v) ? v : null;
  }

  function attach(root, onUid) {
    var btn = root.querySelector('[data-rfid-connect]');
    var status = root.querySelector('[data-rfid-status]');
    var input = root.querySelector('[data-rfid-input]');
    var last = { uid: null, at: 0 };

    function setStatus(text, tone) {
      if (!status) return;
      status.textContent = text;
      status.className = 'status ' + (tone || 'info');
    }

    function emit(raw) {
      var uid = normalise(raw);
      if (!uid) { setStatus('Not a card number: ' + String(raw).slice(0, 24), 'low'); return; }
      var now = Date.now();
      if (uid === last.uid && now - last.at < DEBOUNCE_MS) return; // same card still on the reader
      last = { uid: uid, at: now };
      onUid(uid);
    }

    // ---- keyboard-mode readers --------------------------------------------------------
    if (input) {
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          var v = input.value;
          input.value = '';
          if (v.trim()) emit(v);
        }
      });
    }

    // ---- USB serial readers (Web Serial) ----------------------------------------------
    if (!btn) return;
    if (!('serial' in navigator)) {
      btn.disabled = true;
      btn.title = 'Use Chrome or Edge for a USB serial reader, or a keyboard-mode reader with the box on the right.';
      setStatus('USB reader needs Chrome/Edge — keyboard mode works', 'average');
      return;
    }

    var reading = false;

    async function readFrom(port) {
      if (reading) return;
      reading = true;
      try {
        if (!port.readable) await port.open({ baudRate: 9600 });
        setStatus('Reader connected — tap a card', 'high');
        btn.textContent = 'Reader connected';
        btn.disabled = true;
        var decoder = new TextDecoderStream();
        port.readable.pipeTo(decoder.writable).catch(function () {});
        var reader = decoder.readable.getReader();
        var buffer = '';
        while (true) {
          var chunk = await reader.read();
          if (chunk.done) break;
          buffer += chunk.value;
          var lines = buffer.split(/\r?\n/);
          buffer = lines.pop();
          lines.forEach(function (line) {
            line = line.trim();
            if (line.indexOf('UID:') === 0) emit(line);
            else if (line.indexOf('MELAI-RFID') === 0) setStatus('Reader ready (' + line + ') — tap a card', 'high');
          });
        }
      } catch (err) {
        setStatus('Reader error: ' + (err && err.message ? err.message : err), 'low');
      } finally {
        reading = false;
        btn.disabled = false;
        btn.textContent = 'Connect USB reader';
      }
    }

    btn.addEventListener('click', async function () {
      try {
        var port = await navigator.serial.requestPort();
        readFrom(port);
      } catch (e) { /* user closed the chooser */ }
    });

    // A reader the user already allowed on this site reconnects by itself.
    navigator.serial.getPorts().then(function (ports) { if (ports.length) readFrom(ports[0]); });
    navigator.serial.addEventListener('connect', function (e) { readFrom(e.target); });
    navigator.serial.addEventListener('disconnect', function () { setStatus('Reader unplugged', 'average'); });
  }

  window.MelaiRfid = { attach: attach, normalise: normalise };
})();
