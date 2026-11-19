import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// No card within the timeout (callers that keep listening just retry).
  static const String timeoutMessage = 'No card was tapped. Try again.';

  /// The phone's NFC could not be switched on for reading.
  static const String startFailedMessage =
      'NFC could not start on this phone. Use the counter reader or type the card number.';

  static const String _allowedKey = 'nfc.cards.allowed';
  static const MethodChannel _channel = MethodChannel('ph.melainuts.app/nfc');

  /// Whether staff allowed this app to use THIS phone's NFC for loyalty cards
  /// (the "Allow NFC" button). null = never asked on this phone.
  ///
  /// Android and iOS have no runtime NFC permission (Android grants it at
  /// install), so this in-app choice is what the POS asks for before it turns
  /// the reader on. It is saved on the phone only and can be changed in
  /// Settings > Permissions.
  Future<bool?> allowedOnThisPhone() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_allowedKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> setAllowedOnThisPhone(bool allowed) async {
    if (!allowed) await cancel();
    try {
      await (await SharedPreferences.getInstance()).setBool(_allowedKey, allowed);
    } catch (_) {
      // Not saved: the POS asks again next time.
    }
  }

  /// Opens the phone's NFC settings so NFC can be switched on (Android).
  /// Returns false where that is not possible (iPhone: NFC is always on).
  Future<bool> openNfcSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('openNfcSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

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
  ///
  /// Android: reader mode is on only while this waits, and only while the app
  /// is in front. With reader mode off, Android ignores the card (or shows
  /// "no app supports this tag"), which is why the POS turns it on as soon as
  /// the loyalty dialog opens.
  Future<String> readUid({Duration timeout = const Duration(seconds: 30)}) async {
    await cancel();
    final done = Completer<String>();
    _pending = done;
    try {
      await NfcManager.instance.startSession(
        // ISO 14443 A/B: MIFARE Classic / Ultralight / NTAG / DESFire (the
        // RC522 counter reader's cards). Android: NFC-A + NFC-B reader flags.
        pollingOptions: {NfcPollingOption.iso14443},
        alertMessageIos: 'Hold the customer\'s card near the top of the phone.',
        onDiscovered: (NfcTag tag) async {
          if (done.isCompleted) return;
          Uint8List? id;
          try {
            id = uidBytes(tag);
          } catch (_) {
            id = null;
          }
          if (id == null || id.length < 4) {
            done.completeError(const NfcReadException('This card has no readable ID. Try again or use the counter reader.'));
          } else {
            done.complete(toHex(id));
          }
        },
        // iOS: the person closed the scan sheet, or it timed out.
        onSessionErrorIos: (error) {
          _sessionOpen = false;
          if (!done.isCompleted) done.completeError(const NfcReadException(cancelledMessage));
        },
      );
      _sessionOpen = true;
    } catch (_) {
      if (identical(_pending, done)) _pending = null;
      throw const NfcReadException(startFailedMessage);
    }
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      throw const NfcReadException(timeoutMessage);
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