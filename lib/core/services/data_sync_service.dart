import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// DataSyncService handles local database caching and cloud database synchronization.
///
/// Under the hood, Cloud Firestore maintains an indexed local disk cache
/// (SQLite / LevelDB) on mobile devices. When offline or on low connectivity,
/// reads/writes execute against that local cache and are replayed to the
/// server when connectivity returns.
///
/// SECURITY MODEL
/// * The local cache is a *convenience copy*, never an authority. Every
///   queued write is re-checked by Firestore Security Rules (firestore.rules)
///   when it reaches the server, using the identity that is signed in at that
///   moment. Editing the local cache cannot grant access or change a role.
/// * The cache is not encrypted by Firestore. To limit what a lost/shared
///   device exposes, (a) it is size-bounded, and (b) it is wiped on app start
///   whenever no user is signed in (see [initializeLocalDatabase]).
/// * No passwords, tokens or keys are ever written to it by this app.
class DataSyncService {
  DataSyncService._();
  static final DataSyncService instance = DataSyncService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Firestore's own default cache size (100 MB) — bounded, so stale data
  /// is garbage-collected instead of accumulating forever.
  static const int _cacheSizeBytes = 100 * 1024 * 1024;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Initializes local persistence & caching settings for offline access.
  ///
  /// Must run before any other Firestore call. If no user is signed in
  /// (first launch, or the previous person logged out) any cached data left
  /// on disk is cleared, so a signed-out device holds no business data.
  /// A signed-in user keeps their cache, so the offline workflow is unchanged.
  Future<void> initializeLocalDatabase() async {
    if (_isInitialized) return;

    try {
      if (!kIsWeb) {
        _firestore.settings = const Settings(
          persistenceEnabled: true,
          cacheSizeBytes: _cacheSizeBytes,
        );

        final user = await FirebaseAuth.instance
            .authStateChanges()
            .first
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (user == null) {
          try {
            await _firestore.clearPersistence();
          } catch (_) {
            // Fails harmlessly if Firestore was already started; nothing to do.
          }
        }
      }
      _isInitialized = true;
      if (kDebugMode) debugPrint('Local database & cloud sync initialized.');
    } catch (e) {
      if (kDebugMode) debugPrint('Local database init warning: ${e.runtimeType}');
    }
  }

  /// Best-effort flush of queued local writes. Bounded by a short timeout so
  /// it can never hang (e.g. logout while offline).
  Future<void> syncPendingWrites({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      await _firestore.waitForPendingWrites().timeout(timeout);
    } catch (e) {
      if (kDebugMode) debugPrint('Pending writes not flushed: ${e.runtimeType}');
    }
  }

  /// Disables network to simulate offline mode or save bandwidth.
  Future<void> enableOfflineMode() async {
    await _firestore.disableNetwork();
  }

  /// Re-enables network synchronization with Cloud Firestore.
  Future<void> enableOnlineSync() async {
    await _firestore.enableNetwork();
  }
}
