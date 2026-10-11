import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/staff_session_store.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/staff_context.dart';
import 'package:melai_nuts/data/repositories/staff_local_repository.dart';
import 'package:melai_nuts/data/repositories/staff_profile_repository.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'support/staff_fixtures.dart';
import 'support/test_db.dart';

void main() {
  late Database db;
  late StaffLocalRepository local;
  late FakeStaffAuth auth;
  late DateTime clock;

  setUp(() async {
    db = await openTestDatabase();
    clock = DateTime(2026, 10, 1, 12);
    local = StaffLocalRepository(database: () async => db, now: () => clock);
    auth = FakeStaffAuth();
  });

  tearDown(() async {
    await db.close();
  });

  StaffSessionStore buildStore(
    StaffContextFetcher fetcher, {
    StaffLocalRepository? cache,
    bool useCache = true,
    Future<void> Function()? identitySync,
    List<IdentityPurger> purgers = const <IdentityPurger>[],
  }) {
    return StaffSessionStore.create(
      auth: auth,
      fetcher: fetcher,
      local: useCache ? (cache ?? local) : null,
      identitySync: identitySync,
      identityPurgers: purgers,
      now: () => clock,
    );
  }

  // Results are stamped with the test's fake clock so the cache's age checks
  // are deterministic.
  StaffContextResult ok(String uid, {Map<String, dynamic>? payload}) =>
      activeResult(uid, payload: payload, loadedAt: clock);

  Future<StaffContextResult> servesActive(String uid) async => ok(uid);
  Future<StaffContextResult> offline(String uid) async => throw const SocketException('no route to host');

  group('unauthenticated', () {
    test('nobody signed in: nothing is ready and nothing is granted', () {
      final store = buildStore(servesActive);
      expect(store.status, StaffSessionStatus.signedOut);
      expect(store.phase, StaffBootstrapPhase.initializing);
      expect(store.isReady, isFalse);
      expect(store.context, isNull);
      expect(store.can(StaffPermission.viewDashboard), isFalse);
      expect(store.isReadyFor('anyone'), isFalse);
      expect(store.canAccessBranch('branch-a'), isFalse);
    });

    test('refresh with nobody signed in does nothing', () async {
      var calls = 0;
      final store = buildStore((uid) async {
        calls++;
        return ok(uid);
      });
      expect(await store.refresh(), StaffSessionStatus.signedOut);
      expect(calls, 0);
    });
  });

  group('authenticated staff', () {
    test('a valid active profile becomes ready, server-validated and cached', () async {
      auth.uid = 'staff-a';
      final store = buildStore(servesActive);

      expect(await store.loadForStaff('staff-a'), StaffSessionStatus.ready);

      expect(store.isReady, isTrue);
      expect(store.isServerValidated, isTrue);
      expect(store.isOfflineSession, isFalse);
      expect(store.source, StaffContextSource.server);
      expect(store.phase, StaffBootstrapPhase.ready);
      expect(store.ownerUid, 'staff-a');
      expect(store.branchId, 'branch-a');
      expect(store.can(StaffPermission.manageInventory), isTrue);
      expect(store.can(StaffPermission.manageRefunds), isFalse);
      expect(store.canSensitive(StaffPermission.manageInventory), isTrue);
      expect(store.canAccessBranch('branch-a'), isTrue);
      expect(store.canAccessBranch('branch-b'), isFalse);
      expect(store.isReadyFor('staff-a'), isTrue);
      expect(store.isReadyFor('staff-b'), isFalse);
      expect(() => store.requireServerValidation(), returnsNormally);

      final cached = await local.loadContext('staff-a');
      expect(cached, isNotNull, reason: 'a server confirmation is saved for offline starts');
    });

    test('Firebase says someone else is signed in: the store is not ready for them', () async {
      auth.uid = 'staff-a';
      final store = buildStore(servesActive);
      await store.loadForStaff('staff-a');
      auth.uid = 'staff-b'; // identity swapped underneath
      expect(store.isReadyFor('staff-a'), isFalse);
    });

    test('concurrent loads for the same account share one request', () async {
      auth.uid = 'staff-a';
      var calls = 0;
      final gate = Completer<StaffContextResult>();
      final store = buildStore((uid) {
        calls++;
        return gate.future;
      });
      final first = store.loadForStaff('staff-a');
      final second = store.loadForStaff('staff-a');
      gate.complete(ok('staff-a'));
      await Future.wait([first, second]);
      expect(calls, 1);
    });

    test('the registry email is synced once per account, not on every refresh', () async {
      auth.uid = 'staff-a';
      var syncs = 0;
      final store = buildStore(servesActive, identitySync: () async => syncs++);
      await store.loadForStaff('staff-a');
      await store.refresh();
      expect(syncs, 1);
    });
  });

  group('access is denied unless the profile is active and valid', () {
    const cases = <StaffContextStatus, StaffSessionStatus>{
      StaffContextStatus.notProvisioned: StaffSessionStatus.notProvisioned,
      StaffContextStatus.inactive: StaffSessionStatus.inactive,
      StaffContextStatus.suspended: StaffSessionStatus.suspended,
      StaffContextStatus.invalidRole: StaffSessionStatus.invalidRole,
      StaffContextStatus.invalidBranch: StaffSessionStatus.invalidBranch,
    };
    const errorKinds = <StaffSessionStatus, AppErrorKind>{
      StaffSessionStatus.notProvisioned: AppErrorKind.staffNotProvisioned,
      StaffSessionStatus.inactive: AppErrorKind.accountInactive,
      StaffSessionStatus.suspended: AppErrorKind.accountSuspended,
      StaffSessionStatus.invalidRole: AppErrorKind.invalidRole,
      StaffSessionStatus.invalidBranch: AppErrorKind.invalidBranch,
    };

    cases.forEach((serverStatus, expected) {
      test('${serverStatus.name} -> ${expected.name}: no context, no permissions', () async {
        auth.uid = 'staff-a'; // Firebase authenticated, but that alone grants nothing
        final store = buildStore((_) async => StaffContextResult(serverStatus));

        expect(await store.loadForStaff('staff-a'), expected);

        expect(store.status.isDenied, isTrue);
        expect(store.isReady, isFalse);
        expect(store.context, isNull);
        expect(store.phase, StaffBootstrapPhase.unauthorized);
        expect(store.can(StaffPermission.viewDashboard), isFalse);
        expect(store.isReadyFor('staff-a'), isFalse);
        expect(store.accessError!.kind, errorKinds[expected]);
      });
    });

    test('a deny wipes the offline copy so a restart without network cannot restore it', () async {
      auth.uid = 'staff-a';
      var revoked = false;
      final store = buildStore((uid) async => revoked
          ? const StaffContextResult(StaffContextStatus.suspended)
          : ok(uid));
      await store.loadForStaff('staff-a');
      expect(await local.loadContext('staff-a'), isNotNull);

      revoked = true;
      expect(await store.refresh(), StaffSessionStatus.suspended);
      expect(store.isReady, isFalse, reason: 'a confirmed session does not survive a server deny');
      expect(await local.loadContext('staff-a'), isNull);

      final restarted = buildStore(offline);
      expect(await restarted.loadForStaff('staff-a'), StaffSessionStatus.failed);
      expect(restarted.isReady, isFalse);
    });
  });

  group('offline session restore', () {
    Future<void> seedServerSession(String uid) async {
      auth.uid = uid;
      final store = buildStore(servesActive);
      await store.loadForStaff(uid);
    }

    test('a recently server-confirmed account restores from the cache when offline', () async {
      await seedServerSession('staff-a');

      final restarted = buildStore(offline);
      expect(await restarted.loadForStaff('staff-a'), StaffSessionStatus.ready);

      expect(restarted.isReady, isTrue);
      expect(restarted.isOfflineSession, isTrue);
      expect(restarted.source, StaffContextSource.cache);
      expect(restarted.error!.isConnectivity, isTrue, reason: 'it still knows why it is offline');
      expect(restarted.can(StaffPermission.manageInventory), isTrue);
    });

    test('an offline session is NOT server-validated: sensitive actions wait for the backend', () async {
      await seedServerSession('staff-a');
      final restarted = buildStore(offline);
      await restarted.loadForStaff('staff-a');

      expect(restarted.isServerValidated, isFalse);
      expect(restarted.canSensitive(StaffPermission.manageInventory), isFalse);
      expect(
        () => restarted.requireServerValidation(),
        throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.noInternet)),
      );
    });

    test('reconnecting upgrades the session to server-validated', () async {
      await seedServerSession('staff-a');
      var online = false;
      final restarted = buildStore((uid) async => online ? ok(uid) : throw const SocketException('x'));
      await restarted.loadForStaff('staff-a');
      expect(restarted.isServerValidated, isFalse);

      online = true;
      await restarted.refresh();
      expect(restarted.isServerValidated, isTrue);
      expect(restarted.error, isNull);
    });

    test('offline with nothing cached fails closed (and says it is a connectivity problem)', () async {
      auth.uid = 'staff-a';
      final store = buildStore(offline);
      expect(await store.loadForStaff('staff-a'), StaffSessionStatus.failed);
      expect(store.isReady, isFalse);
      expect(store.context, isNull);
      expect(store.phase, StaffBootstrapPhase.error);
      expect(store.error!.isConnectivity, isTrue);
    });

    test("someone else's cached access is never used for this account", () async {
      await seedServerSession('staff-a');
      auth.uid = 'staff-b';
      final other = buildStore(offline);
      expect(await other.loadForStaff('staff-b'), StaffSessionStatus.failed);
      expect(other.context, isNull);
    });

    test('a cached confirmation older than the limit is not honoured', () async {
      await seedServerSession('staff-a');
      clock = clock.add(StaffLocalRepository.maxOfflineAge + const Duration(minutes: 1));
      final restarted = buildStore(offline);
      expect(await restarted.loadForStaff('staff-a'), StaffSessionStatus.failed);
    });

    test('an offline session stops being ready once its cached confirmation expires', () async {
      await seedServerSession('staff-a');
      final restarted = buildStore(offline);
      await restarted.loadForStaff('staff-a');
      expect(restarted.isReady, isTrue);

      clock = clock.add(StaffLocalRepository.maxOfflineAge + const Duration(minutes: 1));
      expect(restarted.isReady, isFalse);
      expect(restarted.can(StaffPermission.viewDashboard), isFalse);
    });

    test('only connectivity failures fall back to the cache; auth failures lock the session', () async {
      await seedServerSession('staff-a');
      final restarted = buildStore((_) async => throw const AppError(AppErrorKind.authExpired, 'expired'));
      expect(await restarted.loadForStaff('staff-a'), StaffSessionStatus.failed);
      expect(restarted.isReady, isFalse);
    });

    test('a refresh that fails only on connectivity keeps the confirmed session', () async {
      auth.uid = 'staff-a';
      var up = true;
      final store = buildStore((uid) async => up ? ok(uid) : throw const SocketException('x'));
      await store.loadForStaff('staff-a');
      up = false;
      await store.refresh();
      expect(store.isReady, isTrue);
      expect(store.isServerValidated, isTrue, reason: 'still the server-confirmed context from this run');
    });

    test('a refresh that fails for any other reason locks the session', () async {
      auth.uid = 'staff-a';
      var healthy = true;
      final store = buildStore((uid) async =>
          healthy ? ok(uid) : throw const AppError(AppErrorKind.permissionDenied, 'no'));
      await store.loadForStaff('staff-a');
      healthy = false;
      expect(await store.refresh(), StaffSessionStatus.failed);
      expect(store.isReady, isFalse);
    });

    test('a broken local database never blocks a server-confirmed sign-in', () async {
      auth.uid = 'staff-a';
      final broken = StaffLocalRepository(database: () async => throw StateError('disk full'));
      final store = buildStore(servesActive, cache: broken);
      expect(await store.loadForStaff('staff-a'), StaffSessionStatus.ready);
      expect(store.isServerValidated, isTrue);
    });

    test('with no local database at all, offline simply fails closed', () async {
      auth.uid = 'staff-a';
      final store = buildStore(offline, useCache: false);
      expect(await store.loadForStaff('staff-a'), StaffSessionStatus.failed);
    });
  });

  group('switching accounts and signing out', () {
    test('signing out clears profile, permissions, branch access and error', () async {
      auth.uid = 'staff-a';
      final store = buildStore(servesActive)..bindToAuth();
      addTearDown(store.unbindFromAuth);
      await store.loadForStaff('staff-a');
      expect(store.isReady, isTrue);

      auth.signOut();

      expect(store.status, StaffSessionStatus.signedOut);
      expect(store.context, isNull);
      expect(store.ownerUid, isNull);
      expect(store.permissions, isEmpty);
      expect(store.authorizedBranches, isEmpty);
      expect(store.error, isNull);
      expect(store.can(StaffPermission.viewDashboard), isFalse);
      expect(store.phase, StaffBootstrapPhase.initializing);
    });

    test('Staff B never sees any of Staff A: cleared the instant the identity changes', () async {
      auth.uid = 'staff-a';
      final store = buildStore((uid) async => ok(
            uid,
            payload: staffPayload(
              uid: uid,
              branchId: 'branch-$uid',
              branchName: 'Branch $uid',
              refunds: uid == 'staff-a',
              inventory: uid == 'staff-b',
            ),
          ))
        ..bindToAuth();
      addTearDown(store.unbindFromAuth);
      await store.loadForStaff('staff-a');
      expect(store.can(StaffPermission.manageRefunds), isTrue);
      expect(store.branchId, 'branch-staff-a');

      auth.signIn('staff-b'); // B signs in; before B's data even loads...
      expect(store.context, isNull, reason: "A's profile is gone immediately");
      expect(store.branchId, isNull);
      expect(store.can(StaffPermission.manageRefunds), isFalse);
      expect(store.isReadyFor('staff-a'), isFalse);

      await store.loadForStaff('staff-b');
      expect(store.context!.firebaseUid, 'staff-b');
      expect(store.branchId, 'branch-staff-b');
      expect(store.can(StaffPermission.manageRefunds), isFalse, reason: "A's refund right did not carry over");
      expect(store.can(StaffPermission.manageInventory), isTrue);
      expect(store.canAccessBranch('branch-staff-a'), isFalse);
    });

    test("loading B while A is still loaded clears A first (no flash of A's data)", () async {
      auth.uid = 'staff-a';
      final store = buildStore((uid) => uid == 'staff-a' ? servesActive(uid) : Completer<StaffContextResult>().future);
      await store.loadForStaff('staff-a');

      auth.uid = 'staff-b';
      unawaited(store.loadForStaff('staff-b')); // never completes in this test
      expect(store.context, isNull);
      expect(store.status, StaffSessionStatus.loading);
      expect(store.ownerUid, 'staff-b');
      expect(store.phase, StaffBootstrapPhase.loadingProfile);
    });

    test("a slow answer for A that arrives after B signed in is discarded and not cached", () async {
      auth.uid = 'staff-a';
      final slowA = Completer<StaffContextResult>();
      final store = buildStore((uid) => uid == 'staff-a' ? slowA.future : servesActive(uid))..bindToAuth();
      addTearDown(store.unbindFromAuth);

      final loadA = store.loadForStaff('staff-a');
      auth.signIn('staff-b');
      slowA.complete(ok('staff-a'));
      await loadA;

      expect(store.context, isNull, reason: "A's late answer must not land in B's session");
      expect(store.isReadyFor('staff-a'), isFalse);
      expect(await local.loadContext('staff-a'), isNull, reason: "A's late answer must not be cached either");

      await store.loadForStaff('staff-b');
      expect(store.context!.firebaseUid, 'staff-b');
    });

    test('every registered reset hook runs on each identity change, and can be removed', () async {
      auth.uid = 'staff-a';
      final store = buildStore(servesActive)..bindToAuth();
      addTearDown(store.unbindFromAuth);
      var resets = 0;
      final unregister = store.registerResetHook(() => resets++);
      await store.loadForStaff('staff-a');

      auth.signOut();
      expect(resets, 1);

      unregister();
      auth.signIn('staff-b');
      auth.signOut();
      expect(resets, 1);
    });

    test('a failing reset hook cannot stop the others or leave the store populated', () async {
      auth.uid = 'staff-a';
      final store = buildStore(servesActive);
      var second = 0;
      store.registerResetHook(() => throw StateError('hook broke'));
      store.registerResetHook(() => second++);
      await store.loadForStaff('staff-a');

      store.clear();
      expect(second, 1);
      expect(store.context, isNull);
    });

    test("signing in purges everyone else's on-device state, never the new user's", () async {
      final purgedFor = <String>[];
      auth.uid = null;
      final store = buildStore(servesActive, purgers: [
        (uid) async => purgedFor.add(uid),
        (uid) async => throw StateError('purge failed'), // must not break sign-in
      ])
        ..bindToAuth();
      addTearDown(store.unbindFromAuth);

      auth.signIn('staff-b');
      await Future<void>.delayed(Duration.zero);
      expect(purgedFor, ['staff-b']);
      expect(await store.loadForStaff('staff-b'), StaffSessionStatus.ready);

      auth.signOut(); // signing out purges nothing (no uid to keep)
      expect(purgedFor, ['staff-b']);
    });

    test("forgetCachedContext deletes only that account's offline copy", () async {
      for (final uid in ['staff-a', 'staff-b']) {
        auth.uid = uid;
        await buildStore(servesActive).loadForStaff(uid);
      }
      final store = buildStore(servesActive);
      await store.forgetCachedContext('staff-a');
      expect(await local.loadContext('staff-a'), isNull);
      expect(await local.loadContext('staff-b'), isNotNull);
    });
  });

  group('bootstrap phases and notifications', () {
    test('phases move loadingProfile -> ready, and a listener hears about it', () async {
      auth.uid = 'staff-a';
      final gate = Completer<StaffContextResult>();
      final store = buildStore((_) => gate.future);
      final seen = <StaffBootstrapPhase>[];
      store.addListener(() => seen.add(store.phase));

      final load = store.loadForStaff('staff-a');
      expect(store.phase, StaffBootstrapPhase.loadingProfile);
      gate.complete(ok('staff-a'));
      await load;

      expect(seen.first, StaffBootstrapPhase.loadingProfile);
      expect(seen.last, StaffBootstrapPhase.ready);
    });

    test('beginAuthentication shows the authenticating phase and endAuthentication undoes it', () {
      final store = buildStore(servesActive);
      store.beginAuthentication();
      expect(store.phase, StaffBootstrapPhase.authenticating);
      expect(store.isReady, isFalse);
      store.endAuthentication();
      expect(store.phase, StaffBootstrapPhase.initializing);
    });

    test('a staff screen is never ready while loading', () async {
      auth.uid = 'staff-a';
      final store = buildStore((_) => Completer<StaffContextResult>().future);
      unawaited(store.loadForStaff('staff-a'));
      expect(store.status, StaffSessionStatus.loading);
      expect(store.isReady, isFalse);
      expect(store.isReadyFor('staff-a'), isFalse);
    });
  });
}
