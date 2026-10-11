import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// The app's connection state. Later batches extend this with `syncing`,
/// `synced` and `syncError`; today the device is either reachable or not.
enum ConnectionStatus { online, offline }

/// Tracks real device connectivity (not a guess from a failed request) and
/// tells every customer-data screen apart from a network state:
///
///   - `isOnline == true`  -> the device has a network path. Individual
///     requests can still fail (server error, RLS rejection, timeout) —
///     this only means "not airplane mode / no wifi-or-cell".
///   - `isOnline == false` -> nothing customer-facing should claim a write
///     succeeded; screens should show cached data plainly labeled as such.
///
/// On a transition from offline -> online, [_onReconnect] callbacks
/// registered via [onReconnect] fire once each (debounced, so a flapping
/// connection doesn't trigger a refresh storm). `main.dart` registers the
/// real refreshes here: products/stock, orders, customer profile/loyalty,
/// notifications — see the call site for the exact list, matching what the
/// spec asks to resync when connectivity returns.
///
/// This is genuinely a signal about the network path, not a simulation:
/// `connectivity_plus` reports the OS's own connectivity state.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService._()
      : _check = (() => Connectivity().checkConnectivity()),
        _changes = (() => Connectivity().onConnectivityChanged),
        _settleDelay = const Duration(seconds: 1);

  /// Test seam: drive the service with a fake platform source.
  @visibleForTesting
  ConnectivityService.testing({
    required this._check,
    required this._changes,
    this._settleDelay = Duration.zero,
  });

  static final ConnectivityService instance = ConnectivityService._();

  final Future<List<ConnectivityResult>> Function() _check;
  final Stream<List<ConnectivityResult>> Function() _changes;
  final Duration _settleDelay;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounce;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  /// Typed view of [isOnline] for code that will also need the sync states.
  ConnectionStatus get status => _isOnline ? ConnectionStatus.online : ConnectionStatus.offline;

  final List<Future<void> Function()> _reconnectCallbacks = [];

  bool _started = false;

  /// Starts listening. Safe to call more than once (no-op after the first).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final initial = await _check();
      _isOnline = _hasConnection(initial);
    } catch (_) {
      // Plugin unavailable (unsupported platform, etc.) — assume online
      // rather than permanently hiding customer data behind an offline banner.
      _isOnline = true;
    }
    notifyListeners();

    _subscription = _changes().listen((results) {
      final nowOnline = _hasConnection(results);
      if (nowOnline == _isOnline) return;
      final wasOffline = !_isOnline;
      _isOnline = nowOnline;
      notifyListeners();
      if (nowOnline && wasOffline) {
        _debounce?.cancel();
        // Small settle delay: the OS can report "connected" a moment
        // before the network is actually usable (captive portals, DHCP).
        _debounce = Timer(_settleDelay, _fireReconnectCallbacks);
      }
    });
  }

  bool _hasConnection(List<ConnectivityResult> results) {
    return results.any((r) => r != ConnectivityResult.none);
  }

  /// Registers a refresh to run once, shortly after connectivity comes
  /// back from being lost. Exceptions from [callback] are swallowed (best
  /// effort — the screens that need this data already retry/refresh on
  /// their own open, so a failed reconnect refresh is not fatal).
  void onReconnect(Future<void> Function() callback) {
    _reconnectCallbacks.add(callback);
  }

  Future<void> _fireReconnectCallbacks() async {
    for (final cb in _reconnectCallbacks) {
      try {
        await cb();
      } catch (_) {
        // Best-effort; individual screens still refresh themselves on open.
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
