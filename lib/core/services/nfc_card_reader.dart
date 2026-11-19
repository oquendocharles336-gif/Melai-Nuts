import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

enum NfcSupport { available, disabled, unsupported }

class NfcReadException implements Exception {
  final String message;
  const NfcReadException(this.message);
  @override
  String toString() => message;
}

/// Reads the UID of a loyalty card held against the staff phone (POS).
///
/// Only the card's UID is read (the same value the counter readers send);
/// no sector of the card is read or written.
///
/// LIMITS
///   * Android phones with NFC: the UID of MIFARE Classic / Ultralight / NTAG
///     cards is reported by the phone even when the phone's NFC chip cannot
///     read MIFARE Classic data, so this works on most NFC Android phones.
///   * iPhone: Core NFC does not detect MIFARE Classic 1K cards at all
///     (MIFARE Ultralight / NTAG / DESFire work, with the NFC capability
///     enabled in Xcode). The POS then offers the USB reader / typed card number.
///   * Web / desktop: not available.
class NfcCardReader {
  NfcCardReader._();
  static final NfcCardReader instance = NfcCardReader._();

  bool _sessionOpen = false;
  Completer<String>? _pending;

  /// The message of a read stopped by [cancel].
  static const String cancelledMessage = 'Stopped.';

  Future<NfcSupport> support() async {
    if (kIsWeb) return NfcSupport.unsupported;
    if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) {
      return NfcSupport.unsupported;
    }
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (availability == NfcAvailability.enabled) return NfcSupport.available;
      if (availability == NfcAvailability.disabled) return NfcSupport.disabled;
      return NfcSupport.unsupported;
    } catch (_) {
      return NfcSupport.unsupported;
    }
  }

  /// Waits for one card and returns its UID as upper-case hex ("04A1B2C3").
  /// Throws [NfcReadException] on timeout, cancel or an unreadable card.
  Future<String> readUid({Duration timeout = const Duration(seconds: 30)}) async {
    await cancel();
    final done = Completer<String>();
    _pending = done;
    try {
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443},
        alertMessageIos: 'Hold the customer\'s card near the top of the phone.',
        onDiscovered: (NfcTag tag) async {
          final id = uidBytes(tag);
          if (done.isCompleted) return;
          if (id == null || id.length < 4) {
            done.completeError(const NfcReadException('This card has no readable ID. Type the card number instead.'));
          } else {
            done.complete(toHex(id));
          }
        },
      );
      _sessionOpen = true;
    } catch (_) {
      if (identical(_pending, done)) _pending = null;
      throw const NfcReadException('NFC could not start on this phone. Use the reader or type the card number.');
    }
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      throw const NfcReadException('No card was tapped. Try again.');
    } finally {
      if (identical(_pending, done)) _pending = null;
      await _stop(success: done.isCompleted);
    }
  }

  /// Stops a running [readUid] (it then throws [cancelledMessage]).
  Future<void> cancel() async {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const NfcReadException(cancelledMessage));
    }
    await _stop(success: false);
  }

  Future<void> _stop({required bool success}) async {
    if (!_sessionOpen) return;
    _sessionOpen = false;
    try {
      await NfcManager.instance.stopSession(alertMessageIos: success ? 'Card read.' : null);
    } catch (_) {
      // Already closed by the system.
    }
  }

  /// The tag's UID on Android (any tech) and iOS (MIFARE / ISO 7816 families).
  /// (Each platform's `from` casts the tag's platform data, so only the
  /// current platform's classes are asked.)
  static Uint8List? uidBytes(NfcTag tag) {
    if (defaultTargetPlatform == TargetPlatform.android) return NfcTagAndroid.from(tag)?.id;
    final mifare = MiFareIos.from(tag);
    if (mifare != null) return mifare.identifier;
    final iso = Iso7816Ios.from(tag);
    if (iso != null) return iso.identifier;
    return null;
  }

  static String toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}