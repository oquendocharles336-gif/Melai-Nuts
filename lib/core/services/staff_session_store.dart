import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../data/models/staff_context.dart';
import '../../data/repositories/staff_local_repository.dart';
import '../../data/repositories/staff_profile_repository.dart';
import '../utils/app_error.dart';
import 'local_cache_service.dart';
import 'pending_writes_service.dart';

/// Where the staff session stands. Only [ready] unlocks staff screens.
enum StaffSessionStatus {
  /// No staff member is bound to this session.
  signedOut,

  /// The profile / branch / permissions are being fetched.
  loading,

  /// Confirmed active (by the server, or — offline — by a recent cached
  /// server confirmation; see [StaffSessionStore.source]).
  ready,

  /// Signed in, but no staff profile exists for this Firebase account.
  notProvisioned,

  /// An administrator deactivated this staff account.
  inactive,

  /// An administrator suspended this staff account.
  suspended,

  /// The profile carries a role this app does not recognise.
  invalidRole,

  /// The profile has no valid branch assignment.
  invalidBranch,

  /// The server could not be reached / answered badly, and no usable offline
  /// copy exists. Fail closed: staff screens stay locked until a retry
  /// succeeds. See [StaffSessionStore.error].
  failed,
}

extension StaffSessionStatusX on StaffSessionStatus {
  /// The server said this account may NOT work.
  bool get isDenied =>
      this == StaffSessionStatus.notProvisioned ||
      this == StaffSessionStatus.inactive ||
      this == StaffSessionStatus.suspended ||
      this == StaffSessionStatus.invalidRole ||
      this == StaffSessionStatus.invalidBranch;
}

/// The stages of getting from "app opened" to "staff portal usable". UIs can
/// show these; only [ready] ever reveals staff data.
enum StaffBootstrapPhase {
  initializing,
  authenticating,
  loadingProfile,
  validatingAccess,
  loadingBranchAccess,
  ready,
  unauthorized,
  error,
}

/// Where the confirmed context came from.
enum StaffContextSource {
  /// Confirmed by Supabase during this session.
  server,

  /// Restored from the on-device cache because the server was unreachable.
  /// Good enough to keep reading; NOT good enough for sensitive actions.
  cache,
}

/// Who is signed in right now. Firebase in the app; a fake in tests.
abstract class StaffAuthSource {
  String? get currentUid;

  /// Emits the Firebase UID (or null) whenever the signed-in account changes.
  Stream<String?> get uidChanges;
}

class FirebaseStaffAuthSource implements StaffAuthSource {
  const FirebaseStaffAuthSource();

  @override
  String? get currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  Stream<String?> get uidChanges =>
      FirebaseAuth.instance.authStateChanges().map((user) => user?.uid);
}

typedef StaffContextFetcher = Future<StaffContextResult> Function(String uid);

/// Removes on-device state that belongs to anyone other than [uid].
typedef IdentityPurger = Future<void> Function(String uid);

/// The single, identity-bound source of truth for the signed-in staff member's
/// profile, branch assignment and permissions:
///
///   Firebase UID  ->  staff_members row  ->  branches + permissions
///
/// IDENTITY BINDING (no data leakage between accounts)
///  * The store belongs to exactly one Firebase UID at a time ([ownerUid]).
///  * Whenever the Firebase identity changes or disappears — a normal logout,
///    a revoked / expired session, a different person signing in — the store
///    is cleared immediately: profile, branch, permissions, errors, and every
///    hook registered with [registerResetHook] (use that from any later staff
///    store that holds private state: notifications, drafts, in-progress
///    sales, ...). [bindToAuth] wires this to Firebase once at startup, so it
///    does not depend on every logout path remembering to call [clear].
///  * A fetch that finishes after the identity changed is thrown away
///    ([_isCurrent]), so a slow response for Staff A can never land in Staff
///    B's session.
///
/// OFFLINE (see SECURITY.md)
///  * Firebase persists the signed-in session itself; this app never stores a
///    password and there is no offline "login".
///  * After each SERVER confirmation the context is saved to SQLite
///    ([StaffLocalRepository]). If a later start finds the server unreachable,
///    a cached copy for the SAME Firebase UID, confirmed active within
///    [StaffLocalRepository.maxOfflineAge], restores the session with
///    [source] == [StaffContextSource.cache].
///  * A cache-backed session is NOT server-validated ([isServerValidated] is
///    false). Anything sensitive must check it (see [requireServerValidation])
///    and wait for the backend; the database re-checks every request anyway.
///  * The moment the server says inactive / suspended / not provisioned /
///    invalid, the cached copy is deleted, so a revoked account cannot be
///    restored offline.
///
/// FAIL CLOSED: a staff member is [StaffSessionStatus.ready] only after a
/// server (or fresh cached) confirmation of an active profile for THIS uid.
/// On a refresh that fails only because of connectivity the last confirmed
/// context stays usable; any other failure locks the session.
///
/// A [ChangeNotifier] so widgets can wrap themselves in
/// `ListenableBuilder(listenable: StaffSessionStore.instance, ...)`.
class StaffSessionStore extends ChangeNotifier {
  StaffSessionStore._app()
      : this.create(
          auth: const FirebaseStaffAuthSource(),
          fetcher: (uid) => StaffProfileRepository.instance.fetchMyContext(expectedUid: uid),
          local: StaffLocalRepository.instance,
          identitySync: () => StaffProfileRepository.instance.syncMyIdentity(),
          identityPurgers: <IdentityPurger>[
            // Never touches the signed-in account's own data; 'anon' is the
            // public catalog cache shared by everyone.
            (uid) => LocalCache.instance.keepOnly(<String>{'anon', uid}),
            (uid) => PendingWritesService.instance.keepOnlyUser(uid),
            (uid) => StaffLocalRepository.instance.keepOnly(uid),
          ],
        );

  /// Builds a store with explicit collaborators. The app uses [instance];
  /// tests use this with fakes.
  @visibleForTesting
  StaffSessionStore.create({
    required this._auth,
    required this._fetcher,
    this._local,
    this._identitySync,
    this._identityPurgers = const <IdentityPurger>[],
    this._maxOfflineAge = StaffLocalRepository.maxOfflineAge,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final StaffSessionStore instance = StaffSessionStore._app();

  final StaffAuthSource _auth;
  final StaffContextFetcher _fetcher;
  final StaffLocalRepository? _local;
  final Future<void> Function()? _identitySync;
  final List<IdentityPurger> _identityPurgers;
  final Duration _maxOfflineAge;
  final DateTime Function() _now;

  StaffSessionStatus _status = StaffSessionStatus.signedOut;
  StaffBootstrapPhase _phase = StaffBootstrapPhase.initializing;
  StaffContextSource _source = StaffContextSource.server;
  StaffContext? _context;
  AppError? _error;

  /// The Firebase UID this store is currently loading / holding data for.
  String? _ownerUid;

  /// Bumped by every [clear]; invalidates fetches started before it.
  int _generation = 0;

  Future<StaffSessionStatus>? _inFlight;
  String? _inFlightUid;

  /// The uid whose registry email was last synced from the Firebase token.
  String? _identitySyncedFor;

  StreamSubscription<String?>? _authSub;
  final List<VoidCallback> _resetHooks = <VoidCallback>[];

  // ---- Read API -------------------------------------------------------------

  StaffSessionStatus get status => _status;

  StaffBootstrapPhase get phase => _phase;

  /// Where the current context came from; meaningful when [isReady].
  StaffContextSource get source => _source;

  /// The validated staff context, or null unless [status] is
  /// [StaffSessionStatus.ready].
  StaffContext? get context => _context;

  /// Safe, person-readable error from the last failed load; null after a
  /// server success. (A cache-backed session keeps the reason it is offline.)
  AppError? get error => _error;

  /// The Firebase UID the store is bound to, if any.
  String? get ownerUid => _ownerUid;

  bool get _cacheExpired =>
      _source == StaffContextSource.cache &&
      _context != null &&
      _now().difference(_context!.loadedAt) > _maxOfflineAge;

  bool get isReady => _status == StaffSessionStatus.ready && _context != null && !_cacheExpired;

  /// True only when the SERVER confirmed this context during this app run.
  /// Gate sensitive actions on this, not on [isReady].
  bool get isServerValidated => isReady && _source == StaffContextSource.server;

  /// Running on a cached confirmation because the server was unreachable.
  bool get isOfflineSession => isReady && _source == StaffContextSource.cache;

  /// True only when the store holds a confirmed context for [uid] AND [uid] is
  /// the account Firebase currently has signed in. Screens should gate on this,
  /// not on [isReady] alone.
  bool isReadyFor(String uid) =>
      isReady && _context!.firebaseUid == uid && _auth.currentUid == uid;

  String? get branchId => _context?.branchId;
  bool get isOwner => _context?.isOwner ?? false;
  String? get displayName => _context?.fullName;
  Set<String> get permissions => _context?.permissions ?? const <String>{};
  List<StaffBranchRef> get authorizedBranches =>
      _context?.authorizedBranches ?? const <StaffBranchRef>[];

  /// UX-only permission check (see [StaffContext]): false unless [isReady].
  /// The database enforces the same rule independently.
  bool can(String permission) => isReady && _context!.can(permission);

  bool canAny(Iterable<String> candidates) => isReady && _context!.canAny(candidates);

  bool canAll(Iterable<String> required) => isReady && _context!.canAll(required);

  /// Like [can] but also requires the server to have confirmed the session in
  /// this run — use for sensitive actions.
  bool canSensitive(String permission) => isServerValidated && _context!.can(permission);

  bool canAccessBranch(String branchId) => isReady && _context!.canAccessBranch(branchId);

  /// Throws a safe [AppError] unless the server confirmed this session. Call
  /// before any sensitive action; offline sessions must wait for the backend.
  void requireServerValidation() {
    if (isServerValidated) return;
    throw const AppError(
      AppErrorKind.noInternet,
      'This needs a connection so your access can be checked. '
      'Please reconnect and try again.',
    );
  }

  /// The safe, reader-ready reason the session is not usable, or null when it
  /// is. Maps every denied status to its fixed message.
  AppError? get accessError {
    switch (_status) {
      case StaffSessionStatus.notProvisioned:
        return AppErrors.staffNotProvisioned();
      case StaffSessionStatus.inactive:
        return AppErrors.accountInactive();
      case StaffSessionStatus.suspended:
        return AppErrors.accountSuspended();
      case StaffSessionStatus.invalidRole:
        return AppErrors.invalidRole();
      case StaffSessionStatus.invalidBranch:
        return AppErrors.invalidBranch();
      case StaffSessionStatus.failed:
        return _error;
      case StaffSessionStatus.signedOut:
      case StaffSessionStatus.loading:
      case StaffSessionStatus.ready:
        return null;
    }
  }

  // ---- Identity binding -----------------------------------------------------

  /// Starts following the Firebase identity. Call once after
  /// `Firebase.initializeApp` (see main.dart). Idempotent.
  ///
  ///  * A different account (or nobody) is now signed in -> clear everything
  ///    the previous staff member had, synchronously, before any screen can
  ///    rebuild with the new identity.
  ///  * A new account is now signed in -> purge on-device caches and queued
  ///    writes that belong to anyone else (on a shared device, a forced or
  ///    expired sign-out never ran the normal wipe).
  void bindToAuth() {
    if (_authSub != null) return;
    _authSub = _auth.uidChanges.listen((uid) {
      if (uid != _ownerUid) clear();
      if (uid != null) {
        for (final purge in _identityPurgers) {
          try {
            unawaited(purge(uid).catchError((Object _) {}));
          } catch (_) {
            // A purge failing must never break sign-in.
          }
        }
      }
    });
  }

  @visibleForTesting
  Future<void> unbindFromAuth() async {
    await _authSub?.cancel();
    _authSub = null;
  }

  /// Registers a callback that runs every time the staff identity is cleared.
  /// Later staff stores that keep per-person state (notifications, pending
  /// sales, drafts, cached lists, realtime subscriptions) MUST register one so
  /// nothing survives into the next account. Returns a function that
  /// unregisters it.
  VoidCallback registerResetHook(VoidCallback hook) {
    _resetHooks.add(hook);
    return () => _resetHooks.remove(hook);
  }

  /// Marks that a Firebase sign-in is in progress (purely informational for
  /// the [phase]; grants nothing).
  void beginAuthentication() {
    if (_ownerUid != null) return;
    _phase = StaffBootstrapPhase.authenticating;
    notifyListeners();
  }

  /// Ends [beginAuthentication] when no staff session was started (a failed
  /// or non-staff sign-in).
  void endAuthentication() {
    if (_ownerUid != null || _phase != StaffBootstrapPhase.authenticating) return;
    _phase = StaffBootstrapPhase.initializing;
    notifyListeners();
  }

  // ---- Loading --------------------------------------------------------------

  /// Loads (or reloads) the staff context for [uid] — the Firebase UID that is
  /// signed in right now. Concurrent calls for the same uid share one request.
  /// If the store still holds a different account's data it is cleared first.
  ///
  /// Never throws; the returned status (also [status]) is the outcome, with
  /// [error] set for [StaffSessionStatus.failed].
  Future<StaffSessionStatus> loadForStaff(String uid, {bool force = false}) {
    if (_ownerUid != null && _ownerUid != uid) clear();
    if (!force && _ownerUid == uid && isReady) {
      return Future<StaffSessionStatus>.value(_status);
    }
    final running = _inFlight;
    if (running != null && _inFlightUid == uid) return running;

    _ownerUid = uid;
    final generation = _generation;
    final future = _run(uid, generation);
    _inFlight = future;
    _inFlightUid = uid;
    unawaited(future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightUid = null;
      }
    }));
    return future;
  }

  /// Re-reads the server for the account this store is bound to (retry after a
  /// failure, reconnect, pull-to-refresh). A no-op signed-out.
  Future<StaffSessionStatus> refresh() {
    final uid = _ownerUid ?? _auth.currentUid;
    if (uid == null) return Future<StaffSessionStatus>.value(_status);
    return loadForStaff(uid, force: true);
  }

  Future<StaffSessionStatus> _run(String uid, int generation) async {
    // A refresh of an already-confirmed session keeps showing it (no lock
    // flash); a first load shows the loading state.
    final refreshingConfirmed = isReady && _context!.firebaseUid == uid;
    if (!refreshingConfirmed) {
      _context = null;
      _status = StaffSessionStatus.loading;
      _source = StaffContextSource.server;
    }
    _phase = StaffBootstrapPhase.loadingProfile;
    _error = null;
    notifyListeners();

    StaffContextResult? result;
    AppError? failure;
    try {
      result = await _fetcher(uid);
    } catch (e) {
      failure = AppErrors.from(e, scope: ErrorScope.profile);
    }

    // The account changed (or the store was cleared) while we waited: this
    // answer belongs to somebody else. Drop it without touching any state.
    if (!_isCurrent(generation, uid)) return _status;

    if (failure != null) {
      await _applyFailure(uid, generation, failure, refreshingConfirmed);
    } else {
      await _applyResult(uid, generation, result!);
    }
    if (!_isCurrent(generation, uid)) return _status;
    notifyListeners();
    return _status;
  }

  Future<void> _applyFailure(
    String uid,
    int generation,
    AppError failure,
    bool refreshingConfirmed,
  ) async {
    _error = failure;

    // Only connectivity problems may fall back to what we already know. An
    // auth/permission/data failure locks the session.
    if (refreshingConfirmed && failure.isConnectivity) {
      _phase = StaffBootstrapPhase.ready; // keep showing the confirmed session
      return;
    }

    CachedStaffContext? cached;
    if (failure.isConnectivity) cached = await _readCache(uid);
    if (!_isCurrent(generation, uid)) return;

    if (cached != null) {
      _context = cached.context;
      _status = StaffSessionStatus.ready;
      _source = StaffContextSource.cache;
      _phase = StaffBootstrapPhase.ready;
    } else {
      _context = null;
      _status = StaffSessionStatus.failed;
      _phase = StaffBootstrapPhase.error;
    }
  }

  Future<void> _applyResult(String uid, int generation, StaffContextResult result) async {
    _phase = StaffBootstrapPhase.validatingAccess;

    if (result.status == StaffContextStatus.active) {
      final ctx = result.context!;
      _phase = StaffBootstrapPhase.loadingBranchAccess;
      // Persist the server-confirmed copy for offline starts. A disk problem
      // never blocks sign-in: it only means no offline copy.
      await _writeCache(ctx);
      if (!_isCurrent(generation, uid)) {
        // Signed out / switched while we wrote: do not leave their copy behind.
        await _clearCache(uid);
        return;
      }
      _context = ctx;
      _status = StaffSessionStatus.ready;
      _source = StaffContextSource.server;
      _phase = StaffBootstrapPhase.ready;
      _error = null;
      _syncIdentityOnce(uid);
      return;
    }

    // Anything else means this account may NOT work. Forget any offline copy
    // first so the revocation cannot be undone by a restart without network.
    await _clearCache(uid);
    if (!_isCurrent(generation, uid)) return;
    _context = null;
    _phase = StaffBootstrapPhase.unauthorized;
    switch (result.status) {
      case StaffContextStatus.inactive:
        _status = StaffSessionStatus.inactive;
      case StaffContextStatus.suspended:
        _status = StaffSessionStatus.suspended;
      case StaffContextStatus.notProvisioned:
        _status = StaffSessionStatus.notProvisioned;
      case StaffContextStatus.invalidRole:
        _status = StaffSessionStatus.invalidRole;
      case StaffContextStatus.invalidBranch:
        _status = StaffSessionStatus.invalidBranch;
      case StaffContextStatus.active:
        break; // handled above
    }
  }

  bool _isCurrent(int generation, String uid) =>
      generation == _generation && _ownerUid == uid && _auth.currentUid == uid;

  void _syncIdentityOnce(String uid) {
    final sync = _identitySync;
    if (sync == null || _identitySyncedFor == uid) return;
    _identitySyncedFor = uid;
    unawaited(sync().catchError((Object _) {}));
  }

  // ---- Offline cache plumbing (never throws) -----------------------------------

  Future<CachedStaffContext?> _readCache(String uid) async {
    final local = _local;
    if (local == null) return null;
    try {
      return await local.loadContext(uid, maxAge: _maxOfflineAge);
    } catch (e) {
      if (kDebugMode) debugPrint('Staff cache read failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _writeCache(StaffContext context) async {
    final local = _local;
    if (local == null) return;
    try {
      await local.saveContext(context);
    } catch (e) {
      if (kDebugMode) debugPrint('Staff cache write failed: ${e.runtimeType}');
    }
  }

  Future<void> _clearCache(String uid) async {
    final local = _local;
    if (local == null) return;
    try {
      await local.clearContext(uid);
    } catch (e) {
      if (kDebugMode) debugPrint('Staff cache clear failed: ${e.runtimeType}');
    }
  }

  /// Deletes the on-device cached context for [uid]. Called by sign-out after
  /// [clear], so a signed-out device holds no staff authorization.
  Future<void> forgetCachedContext(String uid) => _clearCache(uid);

  // ---- Reset ----------------------------------------------------------------

  /// Forgets the current staff member completely. Runs on sign-out (see
  /// `AuthService.signOut`) and automatically on any identity change (see
  /// [bindToAuth]). Safe to call repeatedly.
  void clear() {
    final hadState = _ownerUid != null ||
        _context != null ||
        _status != StaffSessionStatus.signedOut ||
        _error != null ||
        _phase != StaffBootstrapPhase.initializing;
    _generation++;
    _ownerUid = null;
    _context = null;
    _error = null;
    _inFlight = null;
    _inFlightUid = null;
    _identitySyncedFor = null;
    _source = StaffContextSource.server;
    _status = StaffSessionStatus.signedOut;
    _phase = StaffBootstrapPhase.initializing;

    // Run even when nothing looked loaded: a hook may own state (e.g. a draft)
    // that was created before the context finished loading.
    for (final hook in List<VoidCallback>.of(_resetHooks)) {
      try {
        hook();
      } catch (e) {
        if (kDebugMode) debugPrint('Staff reset hook failed: ${e.runtimeType}');
      }
    }
    if (hadState) notifyListeners();
  }
}
