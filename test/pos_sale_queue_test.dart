import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/sync_service.dart';
import 'package:melai_nuts/data/models/sync_operation.dart';
import 'package:melai_nuts/data/repositories/sync_queue_repository.dart';
import 'package:melai_nuts/features/staff/pos_sale_queue.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/test_db.dart';

/// Offline POS queue: sales saved on the device are replayed with their own
/// idempotency key, so a replay can never ring a sale up twice.
void main() {
  late Database db;
  late SyncQueueRepository queue;
  late SyncService sync;
  var online = true;
  final sentKeys = <String>[];
  Object? failWith;

  setUp(() async {
    db = await openTestDatabase();
    queue = SyncQueueRepository(database: () async => db);
    online = true;
    sentKeys.clear();
    failWith = null;
    sync = SyncService.create(
      queue: queue,
      currentUid: () => 'cashier-a',
      isServerValidated: () => true,
      isOnline: () => online,
      maxAttempts: 3,
    );
  });

  tearDown(() async => db.close());

  PosSaleQueue makeQueue() => PosSaleQueue(
        sync: sync,
        submit: ({
          required String branchId,
          required Map<String, int> quantitiesByVariant,
          required String paymentMethod,
          required String idempotencyKey,
          String? paymentReference,
          double? cashReceived,
          String? customerUid,
        }) async {
          if (failWith != null) throw failWith!;
          sentKeys.add(idempotencyKey);
        },
      );

  Future<SyncOperation> enqueue(PosSaleQueue q, String key) => q.enqueue(
        branchId: 'branch-1',
        quantitiesByVariant: const {'v1': 2},
        paymentMethod: 'cash',
        idempotencyKey: key,
        cashReceived: 500,
        displayedTotal: 180,
      );

  test('a sale saved offline is sent when the connection returns, with its checkout key', () async {
    final q = makeQueue()..register();
    online = false;
    await enqueue(q, 'pos-key-1');
    expect(sentKeys, isEmpty);
    expect((await q.pending()).single.localOperationId, 'pos-key-1');

    online = true;
    await sync.processPending();
    expect(sentKeys, ['pos-key-1']);
    expect(await q.pending(), isEmpty);
    expect((await queue.byId('cashier-a', 'pos-key-1'))!.syncStatus, SyncStatus.synced);
  });

  test('a connection drop during the send keeps the sale pending and re-sends the SAME key', () async {
    final q = makeQueue()..register();
    online = false;
    await enqueue(q, 'pos-key-2');
    online = true;
    failWith = Exception('SocketException: Connection reset');
    await sync.processPending();
    expect((await q.pending()).single.localOperationId, 'pos-key-2');

    failWith = null;
    await sync.processPending();
    expect(sentKeys, ['pos-key-2'], reason: 'one key; the database dedupes a replay');
  });

  test('a sale the database refuses becomes failed, and can be retried or discarded', () async {
    final q = makeQueue()..register();
    online = false;
    await enqueue(q, 'pos-key-3');
    online = true;
    failWith = const PostgrestException(message: 'The requested quantity is not available at this branch.', code: 'P0001');
    await sync.processPending();
    final failed = await q.failed();
    expect(failed.single.localOperationId, 'pos-key-3');
    expect(failed.single.lastError, isNotNull);

    failWith = null;
    await q.retry('pos-key-3');
    await sync.processPending();
    expect(sentKeys, ['pos-key-3']);

    failWith = const PostgrestException(message: 'Open a cash drawer shift first.', code: 'P0001');
    await enqueue(q, 'pos-key-4');
    await sync.processPending();
    expect((await q.failed()).single.localOperationId, 'pos-key-4');
    await q.discard('pos-key-4');
    expect(await q.failed(), isEmpty);
  });
}
