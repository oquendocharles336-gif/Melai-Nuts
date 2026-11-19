import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/loyalty_card.dart';
import '../../data/repositories/loyalty_card_repository.dart';
import '../utils/app_error.dart';
import 'auth_service.dart';
import 'customer_data_store.dart';
import 'supabase_service.dart';

/// Live state of the customer's Golden Kernel Club card for the RFID screen
/// and the loyalty dashboard.
///
/// * [card] is read from the database (`get_my_loyalty_card`), never from a
///   cached profile, so "Active" is shown only while a card is really linked.
/// * "Link my card" opens a 60-second session for one reader; the outcome
///   arrives over realtime (rfid_pairing_sessions), with a slow poll as a
///   fallback when realtime is not connected.
/// * Taps of the customer's linked card (rfid_device_taps) refresh the points.
class LoyaltyCardStore extends ChangeNotifier {
  LoyaltyCardStore._();
  static final LoyaltyCardStore instance = LoyaltyCardStore._();

  final LoyaltyCardRepository _repo = LoyaltyCardRepository.instance;

  bool loading = false;
  bool loadedOnce = false;
  AppError? error;
  MyLoyaltyCard card = MyLoyaltyCard.none;

  List<CardReader> readers = const [];
  AppError? readersError;

  LoyaltyPinStatus? pin;

  CardPairing? pairing;
  bool startingPairing = false;
  AppError? pairingError;

  String? _uid;
  RealtimeChannel? _tapsChannel;
  RealtimeChannel? _pairingChannel;
  Timer? _tick;
  Timer? _poll;

  String? get _currentUid => AuthService.instance.currentFirebaseUser?.uid;

  /// Loads the card, the readers and the PIN status. Safe to call repeatedly.
  Future<void> load() async {
    final uid = _currentUid;
    if (uid == null) return;
    if (_uid != null && _uid != uid) _reset();
    _uid = uid;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait<Object?>([
        _repo.fetchMyCard(),
        _quiet(_repo.fetchReaders, (e) => readersError = e),
        _quiet(_repo.fetchPinStatus, (_) {}),
      ]);
      card = results[0] as MyLoyaltyCard;
      final r = results[1];
      if (r is List<CardReader>) {
        readers = r;
        readersError = null;
      }
      final p = results[2];
      if (p is LoyaltyPinStatus) pin = p;
      loadedOnce = true;
    } catch (e) {
      error = AppErrors.from(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// First load only. Safe to call from build: the load starts after the frame.
  void ensureLoaded() {
    if (loadedOnce || loading || _loadScheduled) return;
    _loadScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (!loadedOnce && !loading) unawaited(load());
    });
  }

  bool _loadScheduled = false;

  Future<T?> _quiet<T>(Future<T> Function() action, void Function(AppError) onError) async {
    try {
      return await action();
    } catch (e) {
      onError(AppErrors.from(e));
      return null;
    }
  }

  Future<void> refreshCard() async {
    try {
      card = await _repo.fetchMyCard();
      error = null;
    } catch (e) {
      error = AppErrors.from(e);
    }
    notifyListeners();
  }

  // ---- Realtime: taps of this customer's card ---------------------------------

  /// Call while the RFID screen is open.
  void watchTaps() {
    final uid = _currentUid;
    if (uid == null || _tapsChannel != null) return;
    _tapsChannel = SupabaseService.instance.client
        .channel('rfid-taps-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'rfid_device_taps',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'firebase_uid', value: uid),
          callback: (_) {
            unawaited(CustomerDataStore.instance.refreshLoyalty());
            unawaited(refreshCard());
          },
        )
        .subscribe();
  }

  void stopWatchingTaps() {
    final ch = _tapsChannel;
    _tapsChannel = null;
    if (ch != null) unawaited(SupabaseService.instance.client.removeChannel(ch));
  }

  // ---- Link my card -------------------------------------------------------------

  Future<void> startPairing(CardReader reader) async {
    if (startingPairing) return;
    startingPairing = true;
    pairingError = null;
    notifyListeners();
    try {
      final p = await _repo.startPairing(reader.id);
      _setPairing(p);
      _listenPairing(p.id);
    } catch (e) {
      pairingError = AppErrors.from(e);
    } finally {
      startingPairing = false;
      notifyListeners();
    }
  }

  Future<void> cancelPairing() async {
    final p = pairing;
    if (p == null) return;
    if (!p.isWaiting) {
      clearPairing();
      return;
    }
    try {
      _setPairing(await _repo.cancelPairing(p.id));
    } catch (e) {
      pairingError = AppErrors.from(e);
      notifyListeners();
    }
  }

  /// Dismisses a finished (or failed) request.
  void clearPairing() {
    _stopPairingWatch();
    pairing = null;
    pairingError = null;
    notifyListeners();
  }

  void _setPairing(CardPairing p) {
    final wasWaiting = pairing?.isWaiting ?? false;
    pairing = p;
    if (!p.isWaiting) {
      _stopPairingWatch();
      if (wasWaiting && p.isSuccess) {
        unawaited(refreshCard());
        unawaited(CustomerDataStore.instance.refreshLoyalty());
      }
    }
    notifyListeners();
  }

  void _listenPairing(String sessionId) {
    _stopPairingWatch();
    _pairingChannel = SupabaseService.instance.client
        .channel('rfid-pairing-$sessionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rfid_pairing_sessions',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: sessionId),
          callback: (payload) {
            final current = pairing;
            if (current == null || current.id != sessionId) return;
            _setPairing(current.mergeRow(payload.newRecord));
          },
        )
        .subscribe();
    // The countdown on screen, and when time is up, ask the server once.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final p = pairing;
      if (p == null || !p.isWaiting) return;
      if (p.secondsLeft <= 0) unawaited(_pollOnce(sessionId));
      notifyListeners();
    });
    // Fallback when realtime is not connected (it never changes the result).
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_pollOnce(sessionId)));
  }

  Future<void> _pollOnce(String sessionId) async {
    final p = pairing;
    if (p == null || p.id != sessionId || !p.isWaiting) return;
    try {
      final fresh = await _repo.fetchPairing(sessionId);
      if (pairing?.id == sessionId && (pairing?.isWaiting ?? false)) _setPairing(fresh);
    } catch (_) {
      // Offline for a moment: the next poll or the realtime event will catch up.
    }
  }

  void _stopPairingWatch() {
    _tick?.cancel();
    _poll?.cancel();
    _tick = null;
    _poll = null;
    final ch = _pairingChannel;
    _pairingChannel = null;
    if (ch != null) unawaited(SupabaseService.instance.client.removeChannel(ch));
  }

  // ---- Lost / stolen ------------------------------------------------------------

  Future<void> blockCard(String? reason) async {
    card = await _repo.blockMyCard(reason);
    pairing = null;
    notifyListeners();
  }

  Future<void> removeCard() async {
    card = await _repo.removeMyCard();
    pairing = null;
    notifyListeners();
  }

  // ---- PIN ------------------------------------------------------------------------

  /// Null on success, otherwise a message for the person.
  Future<String?> setPin(String newPin, {String? currentPin}) async {
    final problem = await _repo.setPin(newPin, currentPin: currentPin);
    if (problem == null) pin = const LoyaltyPinStatus(hasPin: true);
    notifyListeners();
    return problem;
  }

  Future<String?> clearPin(String currentPin) async {
    final problem = await _repo.clearPin(currentPin);
    if (problem == null) pin = const LoyaltyPinStatus(hasPin: false);
    notifyListeners();
    return problem;
  }

  void _reset() {
    _stopPairingWatch();
    stopWatchingTaps();
    card = MyLoyaltyCard.none;
    readers = const [];
    pin = null;
    pairing = null;
    loadedOnce = false;
    error = null;
    readersError = null;
    pairingError = null;
  }

  /// Sign-out.
  void clear() {
    _reset();
    _uid = null;
    notifyListeners();
  }
}
