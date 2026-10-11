import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/sqlite_service.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/sync_operation.dart';
import 'package:melai_nuts/data/repositories/staff_local_repository.dart';
import 'package:melai_nuts/data/repositories/sync_queue_repository.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'support/staff_fixtures.dart';
import 'support/test_db.dart';

void main() {
  late Database db;
  late DateTime clock;
  late StaffLocalRepository staffCache;
  late SyncQueueRepository queue;

  setUp(() async {
    db = await openTestDatabase();
    clock = DateTime(2026, 10, 1, 12);
    staffCache = StaffLocalRepository(database: () async => db, now: () => clock);
    queue = SyncQueueRepository(database: () async => db, now: () => clock);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<Set<String>> tableNames() async {
    final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
    return rows.map((r) => r['name'] as String).toSet();
  }

  group('schema', () {
    test('version 1 creates the staff cache, sync metadata and operation queue', () async {
      expect(await tableNames(), containsAll(['staff_cache', 'sync_metadata', 'sync_operations']));
      final version = await db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, SqliteService.schemaVersion);
    });

    test('the queue only accepts the four known statuses', () async {
      final row = {
        'local_operation_id': 'x',
        'staff_firebase_uid': 'staff-a',
        'operation_type': 't',
        'entity_type': 'e',
        'payload': '{}',
        'created_at': 1,
        'sync_status': 'bogus',
      };
      await expectLater(db.insert('sync_operations', row), throwsA(isA<DatabaseException>()));
    });

    test('no table has a place to store a password or token', () async {
      for (final table in ['staff_cache', 'sync_metadata', 'sync_operations']) {
        final cols = (await db.rawQuery('PRAGMA table_info($table)')).map((c) => (c['name'] as String).toLowerCase());
        for (final c in cols) {
          expect(c, isNot(contains('password')));
          expect(c, isNot(contains('token')));
          expect(c, isNot(contains('secret')));
        }
      }
    });
  });

  group('staff cache', () {
    test('saves and reads back a context (profile, permissions, branches)', () async {
      final ctx = contextFor('staff-a', loadedAt: clock, payload: staffPayload(refunds: true));
      await staffCache.saveContext(ctx);

      final cached = await staffCache.loadContext('staff-a');
      expect(cached, isNotNull);
      expect(cached!.context.firebaseUid, 'staff-a');
      expect(cached.context.permissions, ctx.permissions);
      expect(cached.context.authorizedBranches, ctx.authorizedBranches);
      expect(cached.context.branchId, 'branch-a');
      expect(cached.validatedAt, clock);
    });

    test('saving again replaces the previous copy (one row per person)', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock, payload: staffPayload(refunds: true)));
      expect((await db.query('staff_cache')).length, 1);
      expect((await staffCache.loadContext('staff-a'))!.context.can('manage_refunds'), isTrue);
    });

    test('never returns another account\'s copy', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      expect(await staffCache.loadContext('staff-b'), isNull);
    });

    test('a context that is not active is never stored and clears the old copy', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      await staffCache.saveContext(contextFor('staff-a',
          loadedAt: clock, payload: staffPayload(accountStatus: 'suspended')));
      expect(await staffCache.loadContext('staff-a'), isNull);
      expect(await db.query('staff_cache'), isEmpty);
    });

    test('an expired copy is treated as absent and deleted', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      clock = clock.add(StaffLocalRepository.maxOfflineAge + const Duration(seconds: 1));
      expect(await staffCache.loadContext('staff-a'), isNull);
      expect(await db.query('staff_cache'), isEmpty);
    });

    test('a copy still inside the limit is honoured; a shorter caller limit is respected', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      clock = clock.add(const Duration(hours: 10));
      expect(await staffCache.loadContext('staff-a'), isNotNull);
      expect(await staffCache.loadContext('staff-a', maxAge: const Duration(hours: 1)), isNull);
    });

    test('a copy dated in the future (clock tampering) is rejected', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock.add(const Duration(days: 2))));
      expect(await staffCache.loadContext('staff-a'), isNull);
    });

    test('corrupt stored JSON is discarded, not trusted or crashed on', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      await db.update('staff_cache', {'context_json': '{not json'});
      expect(await staffCache.loadContext('staff-a'), isNull);
      expect(await db.query('staff_cache'), isEmpty);
    });

    test('a row whose JSON names a different account is discarded', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      final forged = jsonEncode(contextFor('staff-b', loadedAt: clock).toJson());
      await db.update('staff_cache', {'context_json': forged}, where: 'firebase_uid = ?', whereArgs: ['staff-a']);
      expect(await staffCache.loadContext('staff-a'), isNull);
    });

    test('a row marked non-active is discarded even if its JSON says active', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      await db.update('staff_cache', {'account_status': 'suspended'});
      expect(await staffCache.loadContext('staff-a'), isNull);
    });

    test('keepOnly removes everyone else\'s copy and keeps the signed-in account\'s', () async {
      for (final uid in ['staff-a', 'staff-b', 'staff-c']) {
        await staffCache.saveContext(contextFor(uid, loadedAt: clock));
      }
      await staffCache.keepOnly('staff-b');
      expect(await staffCache.loadContext('staff-a'), isNull);
      expect(await staffCache.loadContext('staff-c'), isNull);
      expect(await staffCache.loadContext('staff-b'), isNotNull);
    });

    test('clearContext removes one account, clearAll removes everyone', () async {
      await staffCache.saveContext(contextFor('staff-a', loadedAt: clock));
      await staffCache.saveContext(contextFor('staff-b', loadedAt: clock));
      await staffCache.clearContext('staff-a');
      expect(await staffCache.loadContext('staff-a'), isNull);
      expect(await staffCache.loadContext('staff-b'), isNotNull);
      await staffCache.clearAll();
      expect(await db.query('staff_cache'), isEmpty);
    });

    test('database failures surface as a safe local-storage error', () async {
      final closed = await openTestDatabase();
      final repo = StaffLocalRepository(database: () async => closed);
      await closed.close();
      await expectLater(
        repo.loadContext('staff-a'),
        throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.localStorage)),
      );
    });
  });

  group('sync queue', () {
    Future<SyncOperation> add(String uid, {String type = 'inventory.adjust', String? id, String? entityId}) {
      clock = clock.add(const Duration(seconds: 1)); // distinct, ordered timestamps
      return queue.enqueue(
        staffFirebaseUid: uid,
        operationType: type,
        entityType: 'inventory_batch',
        entityId: entityId ?? 'batch-1',
        payload: {'delta': -2, 'note': 'damaged'},
        localOperationId: id,
      );
    }

    test('saves a pending operation with every field the spec requires', () async {
      final op = await add('staff-a', id: 'op-1');
      final stored = await queue.byId('staff-a', 'op-1');

      expect(stored, isNotNull);
      expect(stored!.localOperationId, 'op-1');
      expect(stored.staffFirebaseUid, 'staff-a');
      expect(stored.operationType, 'inventory.adjust');
      expect(stored.entityType, 'inventory_batch');
      expect(stored.entityId, 'batch-1');
      expect(stored.payload, {'delta': -2, 'note': 'damaged'});
      expect(stored.createdAt, op.createdAt);
      expect(stored.retryCount, 0);
      expect(stored.syncStatus, SyncStatus.pending);
      expect(stored.lastError, isNull);
      expect(stored.lastAttemptAt, isNull);
    });

    test('generates a unique operation id when none is given', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        ids.add((await add('staff-a')).localOperationId);
      }
      expect(ids.length, 20);
      expect(ids.every((id) => id.length <= 64), isTrue, reason: 'it doubles as the server idempotency key');
    });

    test('rejects an operation with no owner or type', () {
      expect(
        () => queue.enqueue(staffFirebaseUid: '', operationType: 't', entityType: 'e', payload: {}),
        throwsArgumentError,
      );
      expect(
        () => queue.enqueue(staffFirebaseUid: 'a', operationType: '', entityType: 'e', payload: {}),
        throwsArgumentError,
      );
    });

    test('a duplicate operation id is refused rather than silently replacing', () async {
      await add('staff-a', id: 'dup');
      await expectLater(add('staff-a', id: 'dup'), throwsA(isA<AppError>()));
    });

    test('returns operations oldest first', () async {
      await add('staff-a', id: 'first');
      await add('staff-a', id: 'second');
      await add('staff-a', id: 'third');
      final ops = await queue.withStatus('staff-a', SyncStatus.pending);
      expect(ops.map((o) => o.localOperationId), ['first', 'second', 'third']);
    });

    test("a staff member can never see, change or discard another's operations", () async {
      await add('staff-a', id: 'a-op');
      expect(await queue.withStatus('staff-b', SyncStatus.pending), isEmpty);
      expect(await queue.byId('staff-b', 'a-op'), isNull);

      await queue.markSynced('staff-b', 'a-op');
      await queue.markFailed('staff-b', 'a-op', 'x');
      await queue.discardFailed('staff-b', 'a-op');
      await queue.requeueFailed('staff-b', 'a-op');
      await queue.recoverInterrupted('staff-b');
      await queue.tidyForSignOut('staff-b');

      final untouched = await queue.byId('staff-a', 'a-op');
      expect(untouched!.syncStatus, SyncStatus.pending);
      expect(untouched.retryCount, 0);
    });

    test('tracks attempts: syncing, retry and failure', () async {
      await add('staff-a', id: 'op');

      clock = clock.add(const Duration(seconds: 5));
      await queue.markSyncing('staff-a', 'op');
      var op = (await queue.byId('staff-a', 'op'))!;
      expect(op.syncStatus, SyncStatus.syncing);
      expect(op.lastAttemptAt, clock);

      await queue.markRetry('staff-a', 'op', 'No connection');
      op = (await queue.byId('staff-a', 'op'))!;
      expect(op.syncStatus, SyncStatus.pending);
      expect(op.retryCount, 1);
      expect(op.lastError, 'No connection');

      await queue.markFailed('staff-a', 'op', 'Refused');
      op = (await queue.byId('staff-a', 'op'))!;
      expect(op.syncStatus, SyncStatus.failed);
      expect(op.retryCount, 2);
      expect(op.lastError, 'Refused');

      await queue.markSynced('staff-a', 'op');
      op = (await queue.byId('staff-a', 'op'))!;
      expect(op.syncStatus, SyncStatus.synced);
      expect(op.lastError, isNull);
    });

    test('only a FAILED operation can be requeued or discarded; pending ones are safe', () async {
      await add('staff-a', id: 'pending-op');
      await add('staff-a', id: 'failed-op');
      await queue.markFailed('staff-a', 'failed-op', 'Refused');

      await queue.discardFailed('staff-a', 'pending-op');
      expect(await queue.byId('staff-a', 'pending-op'), isNotNull);

      await queue.requeueFailed('staff-a', 'failed-op');
      expect((await queue.byId('staff-a', 'failed-op'))!.syncStatus, SyncStatus.pending);

      await queue.markFailed('staff-a', 'failed-op', 'Refused again');
      await queue.discardFailed('staff-a', 'failed-op');
      expect(await queue.byId('staff-a', 'failed-op'), isNull);
    });

    test('an operation interrupted mid-send goes back to pending', () async {
      await add('staff-a', id: 'op');
      await queue.markSyncing('staff-a', 'op');
      await queue.recoverInterrupted('staff-a');
      expect((await queue.byId('staff-a', 'op'))!.syncStatus, SyncStatus.pending);
    });

    test('sign-out tidy drops only synced operations and NEVER unsent or failed ones', () async {
      for (final id in ['synced', 'pending', 'failed', 'syncing']) {
        await add('staff-a', id: id);
      }
      await add('staff-b', id: 'b-synced');
      await queue.markSynced('staff-a', 'synced');
      await queue.markFailed('staff-a', 'failed', 'Refused');
      await queue.markSyncing('staff-a', 'syncing');
      await queue.markSynced('staff-b', 'b-synced');

      await queue.tidyForSignOut('staff-a');

      expect(await queue.byId('staff-a', 'synced'), isNull);
      expect((await queue.byId('staff-a', 'pending'))!.syncStatus, SyncStatus.pending);
      expect((await queue.byId('staff-a', 'failed'))!.syncStatus, SyncStatus.failed);
      expect((await queue.byId('staff-a', 'syncing'))!.syncStatus, SyncStatus.pending, reason: 'recovered, not lost');
      expect(await queue.byId('staff-b', 'b-synced'), isNotNull, reason: "another account's rows are untouched");
    });

    test('counts operations per status for one account only', () async {
      await add('staff-a', id: '1');
      await add('staff-a', id: '2');
      await add('staff-a', id: '3');
      await add('staff-b', id: '4');
      await queue.markFailed('staff-a', '3', 'x');
      final counts = await queue.countsByStatus('staff-a');
      expect(counts[SyncStatus.pending], 2);
      expect(counts[SyncStatus.failed], 1);
      expect(counts[SyncStatus.synced], 0);
      expect(counts[SyncStatus.syncing], 0);
    });
  });
}
