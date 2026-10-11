import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/services/customer_local_db.dart';
import 'package:melai_nuts/core/services/sqlite_service.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'support/test_db.dart';

/// The customer's on-device database (SqliteService schema v2): local-first
/// lists, offline search / sort / filter, per-account separation.
void main() {
  late Database db;
  late DateTime clock;
  late CustomerLocalDb local;

  // Shapes copied from the Supabase rows the repositories select (test data,
  // never shipped in the app).
  Map<String, dynamic> order(String id, String status, double total, String createdAt, {String product = 'Kasoy'}) => {
        'id': id,
        'status': status,
        'total': total,
        'branch_name': 'Test Branch',
        'created_at': createdAt,
        'order_items': [
          {'product_name': product, 'variant_label': '250 g'},
        ],
      };

  setUp(() async {
    db = await openTestDatabase();
    clock = DateTime(2026, 10, 11, 9);
    local = CustomerLocalDb(database: () async => db, now: () => clock);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test('schema version 2 adds the customer tables with indexes', () async {
    expect(SqliteService.schemaVersion, greaterThanOrEqualTo(2));
    final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
        .map((r) => r['name'])
        .toSet();
    expect(tables, containsAll(['customer_records', 'response_cache', 'customer_pending_writes']));
    final indexes = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'customer_records'"));
    expect(indexes, isNotEmpty);
  });

  test('no customer table has a place for a password, token or key', () async {
    for (final table in ['customer_records', 'response_cache', 'customer_pending_writes']) {
      final cols = (await db.rawQuery('PRAGMA table_info($table)')).map((c) => (c['name'] as String).toLowerCase());
      for (final c in cols) {
        expect(c, isNot(anyOf(contains('password'), contains('token'), contains('secret'))), reason: '$table.$c');
      }
    }
  });

  test('replaceAll keeps exactly the latest server list (server wins)', () async {
    await local.replaceAll('uid-a', LocalKind.orders, [
      order('ORD-1', 'completed', 100, '2026-10-01T10:00:00Z'),
      order('ORD-2', 'pending', 50, '2026-10-02T10:00:00Z'),
    ]);
    await local.replaceAll('uid-a', LocalKind.orders, [order('ORD-2', 'completed', 50, '2026-10-02T10:00:00Z')]);
    final page = await local.query('uid-a', LocalKind.orders);
    expect(page.total, 1);
    expect(page.rows.single['id'], 'ORD-2');
    expect(page.rows.single['status'], 'completed');
    expect(page.savedAt, clock);
  });

  test('search matches every word, including embedded item names', () async {
    await local.replaceAll('uid-a', LocalKind.orders, [
      order('ORD-1', 'completed', 100, '2026-10-01T10:00:00Z', product: 'Roasted Kasoy'),
      order('ORD-2', 'completed', 80, '2026-10-02T10:00:00Z', product: 'Garlic Mani'),
    ]);
    expect((await local.query('uid-a', LocalKind.orders, search: 'kasoy')).rows.map((r) => r['id']), ['ORD-1']);
    expect((await local.query('uid-a', LocalKind.orders, search: 'garlic mani')).total, 1);
    expect((await local.query('uid-a', LocalKind.orders, search: 'garlic kasoy')).total, 0);
    // LIKE wildcards typed by the user are literal characters.
    expect((await local.query('uid-a', LocalKind.orders, search: '%')).total, 0);
  });

  test('status filter, sort and paging run in SQLite', () async {
    await local.replaceAll('uid-a', LocalKind.orders, [
      for (var i = 1; i <= 30; i++)
        order('ORD-$i', i.isEven ? 'completed' : 'cancelled', i * 10.0,
            '2026-10-${i.toString().padLeft(2, '0')}T10:00:00Z'),
    ]);
    final newest = await local.query('uid-a', LocalKind.orders, sort: LocalSort.newest, limit: 5);
    expect(newest.total, 30);
    expect(newest.rows.first['id'], 'ORD-30');
    expect(newest.rows, hasLength(5));
    final second = await local.query('uid-a', LocalKind.orders, sort: LocalSort.newest, limit: 5, offset: 5);
    expect(second.rows.first['id'], 'ORD-25');
    final cancelled = await local.query('uid-a', LocalKind.orders, status: 'cancelled');
    expect(cancelled.total, 15);
    final priciest = await local.query('uid-a', LocalKind.orders, sort: LocalSort.amountDesc, limit: 1);
    expect(priciest.rows.single['id'], 'ORD-30');
  });

  test('accounts never see each other, and sign-out wipes only that account', () async {
    await local.replaceAll('uid-a', LocalKind.orders, [order('ORD-A', 'completed', 1, '2026-10-01T10:00:00Z')]);
    await local.replaceAll('uid-b', LocalKind.orders, [order('ORD-B', 'completed', 1, '2026-10-01T10:00:00Z')]);
    expect((await local.query('uid-a', LocalKind.orders)).rows.single['id'], 'ORD-A');
    await local.clearScope('uid-a');
    expect((await local.query('uid-a', LocalKind.orders)).total, 0);
    expect((await local.query('uid-b', LocalKind.orders)).total, 1);
    await local.keepOnly({'anon'});
    expect((await local.query('uid-b', LocalKind.orders)).total, 0);
  });

  test('saved responses round-trip and stay bounded', () async {
    expect(await local.putResponse('anon', 'k1', '{"a":1}'), isTrue);
    final saved = await local.getResponse('anon', 'k1');
    expect(saved?.$1, '{"a":1}');
    expect(saved?.$2, clock);
    for (var i = 0; i < CustomerLocalDb.maxResponsesPerScope + 5; i++) {
      clock = clock.add(const Duration(seconds: 1));
      await local.putResponse('anon', 'key-$i', 'v');
    }
    final count = await db.rawQuery("SELECT COUNT(*) AS n FROM response_cache WHERE scope = 'anon'");
    expect(count.first['n'], CustomerLocalDb.maxResponsesPerScope);
  });

  test('without a database (web) every call is a quiet no-op', () async {
    final none = CustomerLocalDb(database: () async => null);
    await none.replaceAll('uid-a', LocalKind.orders, [order('ORD-1', 'completed', 1, '2026-10-01T10:00:00Z')]);
    final page = await none.query('uid-a', LocalKind.orders);
    expect(page.total, 0);
    expect(page.savedAt, isNull);
    expect(await none.getResponse('anon', 'k'), isNull);
  });
}
