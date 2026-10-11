import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/audit_service.dart';
import 'package:melai_nuts/core/services/sync_service.dart';
import 'package:melai_nuts/core/utils/app_error.dart';
import 'package:melai_nuts/data/models/sync_operation.dart';
import 'package:melai_nuts/data/repositories/sync_queue_repository.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'support/test_db.dart';

void main() {
  late Database db;
  late SyncQueueRepository queue;
  late SyncService sync;

  // What the (fake) session and network currently look like.
  String? uid;
  var online = true;
  var validated = true;

  setUp(() async {
    db = await openTestDatabase();
    queue = SyncQueueRepository(database: () async => db);
    uid = 'staff-a';
    online = true;
    validated = true;
    sync = SyncService.create(
      queue: queue,
      currentUid: () => uid,
      isServerValidated: () => validated,
      isOnline: () => online,
      maxAttempts: 2,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<SyncOperation> add(String owner, String id, {String type = 'inventory.adjust'}) =>
      queue.enqueue(
        staffFirebaseUid: owner,
        operationType: type,
        entityType: 'inventory_batch',
        payload: {'id': id},
        localOperationId: id,
      );

  Future<SyncStatus> statusOf(String owner, String id) async =>
      (await queue.byId(owner, id))!.syncStatus;

  group('SyncService.processPending', () {
    test('sends pending operations oldest first and marks them synced', () async {
      final sent = <String>[];
      sync.registerHandler('inventory.adjust', (op) async => sent.add(op.localOperationId));
      await add('staff-a', 'one');
      await add('staff-a', 'two');

      await sync.processPending();

      expect(sent, ['one', 'two']);
      expect(await statusOf('staff-a', 'one'), SyncStatus.synced);
      expect(await statusOf('staff-a', 'two'), SyncStatus.synced);
      expect(sync.pendingCount, 0);
    });

    test('does nothing while offline', () async {
      var calls = 0;
      sync.registerHandler('inventory.adjust', (op) async => calls++);
      await add('staff-a', 'one');
      online = false;
      await sync.processPending();
      expect(calls, 0);
      expect(await statusOf('staff-a', 'one'), SyncStatus.pending);
    });

    test('does nothing on an offline, cache-backed session (not server-validated)', () async {
      var calls = 0;
      sync.registerHandler('inventory.adjust', (op) async => calls++);
      await add('staff-a', 'one');
      validated = false;
      await sync.processPending();
      expect(calls, 0);
      expect(await statusOf('staff-a', 'one'), SyncStatus.pending);
    });

    test('does nothing when nobody is signed in', () async {
      var calls = 0;
      sync.registerHandler('inventory.adjust', (op) async => calls++);
      await add('staff-a', 'one');
      uid = null;
      await sync.processPending();
      expect(calls, 0);
    });

    test("never sends another staff member's operations", () async {
      final sent = <String>[];
      sync.registerHandler('inventory.adjust', (op) async => sent.add(op.localOperationId));
      await add('staff-a', 'mine');
      await add('staff-b', 'theirs');

      await sync.processPending();

      expect(sent, ['mine']);
      expect(await statusOf('staff-b', 'theirs'), SyncStatus.pending);
    });

    test('an operation with no handler yet stays pending - it is not failed or dropped', () async {
      await add('staff-a', 'future-type', type: 'orders.update');
      await sync.processPending();
      expect(await statusOf('staff-a', 'future-type'), SyncStatus.pending);
    });

    test('a server refusal marks that operation failed, with its message, and carries on', () async {
      sync.registerHandler('inventory.adjust', (op) async {
        if (op.localOperationId == 'bad') throw const SyncRejectedException('That quantity is not allowed.');
      });
      await add('staff-a', 'bad');
      await add('staff-a', 'good');

      await sync.processPending();

      final bad = (await queue.byId('staff-a', 'bad'))!;
      expect(bad.syncStatus, SyncStatus.failed);
      expect(bad.lastError, 'That quantity is not allowed.');
      expect(await statusOf('staff-a', 'good'), SyncStatus.synced);
      expect(sync.failedCount, 1);
    });

    test('a connectivity failure keeps the operation pending, counts the attempt and stops the run', () async {
      final attempted = <String>[];
      sync.registerHandler('inventory.adjust', (op) async {
        attempted.add(op.localOperationId);
        throw const SocketException('network down');
      });
      await add('staff-a', 'one');
      await add('staff-a', 'two');

      await sync.processPending();

      expect(attempted, ['one'], reason: 'order is preserved: two must not overtake one');
      final one = (await queue.byId('staff-a', 'one'))!;
      expect(one.syncStatus, SyncStatus.pending);
      expect(one.retryCount, 1);
      expect(one.lastError, isNotNull);
      expect(await statusOf('staff-a', 'two'), SyncStatus.pending);
    });

    test('an unexpected error is retried, then failed once attempts run out', () async {
      sync.registerHandler('inventory.adjust', (op) async => throw StateError('something odd'));
      await add('staff-a', 'one');

      await sync.processPending();
      expect(await statusOf('staff-a', 'one'), SyncStatus.pending);

      await sync.processPending();
      final one = (await queue.byId('staff-a', 'one'))!;
      expect(one.syncStatus, SyncStatus.failed);
      expect(one.retryCount, 2);
    });

    test('a permission error is failed straight away (retrying cannot help)', () async {
      sync.registerHandler(
        'inventory.adjust',
        (op) async => throw const AppError(AppErrorKind.permissionDenied, 'Not allowed.'),
      );
      await add('staff-a', 'one');
      await sync.processPending();
      expect(await statusOf('staff-a', 'one'), SyncStatus.failed);
    });

    test('stops the moment the signed-in account changes mid-run', () async {
      final sent = <String>[];
      sync.registerHandler('inventory.adjust', (op) async {
        sent.add(op.localOperationId);
        uid = 'staff-b'; // someone else signs in while we are sending
      });
      await add('staff-a', 'one');
      await add('staff-a', 'two');

      await sync.processPending();

      expect(sent, ['one']);
      expect(await statusOf('staff-a', 'two'), SyncStatus.pending);
    });

    test('overlapping calls share one run (nothing is sent twice)', () async {
      var calls = 0;
      final gate = Completer<void>();
      sync.registerHandler('inventory.adjust', (op) async {
        calls++;
        await gate.future;
      });
      await add('staff-a', 'one');

      final first = sync.processPending();
      final second = sync.processPending();
      expect(sync.isProcessing, isTrue);
      gate.complete();
      await Future.wait([first, second]);

      expect(calls, 1);
      expect(sync.isProcessing, isFalse);
    });

    test('an operation left in "syncing" by a crash is re-sent', () async {
      var calls = 0;
      sync.registerHandler('inventory.adjust', (op) async => calls++);
      await add('staff-a', 'one');
      await queue.markSyncing('staff-a', 'one');
      await sync.processPending();
      expect(calls, 1);
      expect(await statusOf('staff-a', 'one'), SyncStatus.synced);
    });
  });

  group('SyncService.enqueue and housekeeping', () {
    test('enqueue is durable and sends straight away when it can', () async {
      final sent = <String>[];
      sync.registerHandler('inventory.adjust', (op) async => sent.add(op.localOperationId));

      final op = await sync.enqueue(
        operationType: 'inventory.adjust',
        entityType: 'inventory_batch',
        payload: {'delta': 1},
      );
      await sync.processPending();

      expect(op.staffFirebaseUid, 'staff-a');
      expect(sent, [op.localOperationId]);
      expect(await statusOf('staff-a', op.localOperationId), SyncStatus.synced);
    });

    test('enqueue while offline just saves it', () async {
      online = false;
      final op = await sync.enqueue(
        operationType: 'inventory.adjust',
        entityType: 'inventory_batch',
        payload: {'delta': 1},
      );
      expect(await statusOf('staff-a', op.localOperationId), SyncStatus.pending);
      expect(sync.pendingCount, 1);
    });

    test('enqueue with nobody signed in is refused', () async {
      uid = null;
      await expectLater(
        sync.enqueue(operationType: 't', entityType: 'e', payload: {}),
        throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.accessDenied)),
      );
    });

    test('resetState forgets the counters but not the queued work', () async {
      online = false;
      await sync.enqueue(operationType: 't', entityType: 'e', payload: {});
      expect(sync.pendingCount, 1);
      sync.resetState();
      expect(sync.pendingCount, 0);
      expect(await queue.withStatus('staff-a', SyncStatus.pending), hasLength(1));
    });

    test('counters follow the signed-in account', () async {
      await add('staff-a', 'mine');
      await add('staff-b', 'theirs');
      await sync.refreshCounts();
      expect(sync.pendingCount, 1);
      uid = 'staff-b';
      await sync.refreshCounts();
      expect(sync.pendingCount, 1);
      uid = 'staff-c';
      await sync.refreshCounts();
      expect(sync.pendingCount, 0);
    });

    test('flushBeforeSignOut is bounded even if a send hangs, and queued work survives', () async {
      sync.registerHandler('inventory.adjust', (op) => Completer<void>().future);
      await add('staff-a', 'one');
      await sync.flushBeforeSignOut(timeout: const Duration(milliseconds: 50));
      await sync.tidyForSignOut('staff-a');
      expect(await queue.byId('staff-a', 'one'), isNotNull);
    });
  });

  group('AuditService', () {
    late List<Map<String, dynamic>> rpcCalls;
    Object? rpcError;
    late AuditService audit;

    setUp(() {
      rpcCalls = [];
      rpcError = null;
      audit = AuditService.create(
        sync: sync,
        rpc: (fn, params) async {
          if (rpcError != null) throw rpcError!;
          rpcCalls.add({'fn': fn, ...params});
          return 'new-id';
        },
        fetchRows: (limit) async => [
          {
            'id': 'a1',
            'staff_firebase_uid': 'staff-a',
            'branch_id': 'branch-a',
            'action': 'inventory.adjust',
            'entity_type': 'inventory_batch',
            'entity_id': 'b-1',
            'metadata': {'delta': -2},
            'created_at': '2026-10-01T04:00:00Z',
          },
        ],
      )..registerWithSync();
    });

    test('rejects malformed actions, entity types and oversized metadata before anything is stored', () {
      for (final bad in ['Inventory.Adjust', 'drop table;', '', 'a..b', '.x']) {
        expect(() => audit.record(action: bad, auditedEntityType: 'thing'), throwsArgumentError, reason: bad);
      }
      expect(() => audit.record(action: 'a.b', auditedEntityType: 'Bad-Type'), throwsArgumentError);
      expect(
        () => audit.record(action: 'a.b', auditedEntityType: 'thing', metadata: {'x': 'y' * 7000}),
        throwsArgumentError,
      );
    });

    test('recorded offline: saved durably and sent once the session is server-validated', () async {
      online = false;
      final op = await audit.record(
        action: 'inventory.adjust',
        auditedEntityType: 'inventory_batch',
        entityId: 'b-1',
        metadata: {'delta': -2},
      );
      expect(rpcCalls, isEmpty);
      expect(op.operationType, AuditService.operationType);
      expect(await statusOf('staff-a', op.localOperationId), SyncStatus.pending);

      online = true;
      await sync.processPending();

      expect(await statusOf('staff-a', op.localOperationId), SyncStatus.synced);
      expect(rpcCalls, hasLength(1));
    });

    test('sends the server only a description of the action, with the operation id as idempotency key', () async {
      final op = await audit.record(
        action: 'refund.approve',
        auditedEntityType: 'refund',
        entityId: 'r-9',
        metadata: {'amount': 120},
      );
      await sync.processPending();

      final call = rpcCalls.single;
      expect(call['fn'], 'staff_log_audit');
      expect(call['p_action'], 'refund.approve');
      expect(call['p_entity_type'], 'refund');
      expect(call['p_entity_id'], 'r-9');
      expect(call['p_metadata'], {'amount': 120});
      expect(call['p_client_operation_id'], op.localOperationId);
      expect(
        call.keys.toSet(),
        {'fn', 'p_action', 'p_entity_type', 'p_entity_id', 'p_metadata', 'p_client_operation_id'},
        reason: 'who and which branch are decided by the server, never claimed by the client',
      );
    });

    test('a network failure keeps the entry pending for the next attempt', () async {
      rpcError = const SocketException('down');
      final op = await audit.record(action: 'a.b', auditedEntityType: 'thing');
      await sync.processPending();
      expect(await statusOf('staff-a', op.localOperationId), SyncStatus.pending);
    });

    test('a server rejection is marked failed instead of retried forever', () async {
      rpcError = const AppError(AppErrorKind.invalidData, 'Bad audit entry.');
      final op = await audit.record(action: 'a.b', auditedEntityType: 'thing');
      await sync.processPending();
      final stored = (await queue.byId('staff-a', op.localOperationId))!;
      expect(stored.syncStatus, SyncStatus.failed);
      expect(stored.lastError, 'Bad audit entry.');
    });

    test('fetchRecent parses audit rows', () async {
      final entries = await audit.fetchRecent();
      expect(entries, hasLength(1));
      expect(entries.single.action, 'inventory.adjust');
      expect(entries.single.staffFirebaseUid, 'staff-a');
      expect(entries.single.metadata, {'delta': -2});
      expect(entries.single.createdAt.toUtc(), DateTime.utc(2026, 10, 1, 4));
    });

    test('fetchRecent turns a malformed row into a safe error', () async {
      final bad = AuditService.create(
        sync: sync,
        rpc: (fn, params) async => null,
        fetchRows: (limit) async => [
          {'id': 1}
        ],
      );
      await expectLater(
        bad.fetchRecent(),
        throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.invalidData)),
      );
    });

    test('fetchRecent caps the requested page size', () async {
      int? asked;
      final capped = AuditService.create(
        sync: sync,
        rpc: (fn, params) async => null,
        fetchRows: (limit) async {
          asked = limit;
          return const <Map<String, dynamic>>[];
        },
      );
      await capped.fetchRecent(limit: 100000);
      expect(asked, 200);
    });
  });
}
