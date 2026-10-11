import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../utils/app_error.dart';
import 'sqlite_service.dart';

/// Record types kept in the customer's local database.
class LocalKind {
  LocalKind._();
  static const String products = 'products';
  static const String categories = 'categories';
  static const String orders = 'orders';
  static const String loyalty = 'loyalty_transactions';
  static const String notifications = 'notifications';
  static const String refunds = 'refunds';
  static const String addresses = 'addresses';
  static const String favorites = 'favorites';
  static const String profile = 'profile';
  static const String payments = 'payments';
}

/// Sort fields a local query may use (each one is an indexed column).
enum LocalSort { newest, oldest, titleAsc, titleDesc, amountAsc, amountDesc, serverOrder }

/// One page read from the local database.
class LocalPage {
  const LocalPage(this.rows, this.total, this.savedAt);

  /// The server rows exactly as they were received (decode with each model's
  /// `fromRow`).
  final List<Map<String, dynamic>> rows;

  /// How many records match the search / filter (all pages).
  final int total;

  /// When the oldest of these records was last refreshed from the server
  /// ("last updated" label); null when nothing is stored.
  final DateTime? savedAt;
}

/// The customer side's local SQLite database (tables in SqliteService
/// version 2). It holds the **last server copy** of the signed-in customer's
/// records so screens can show them immediately (local-first), work offline,
/// and search / sort / filter them on the device.
///
/// Rules (docs/ARCHITECTURE.md):
///  * Nothing here is authoritative: the server always wins. A live fetch
///    replaces the stored copy of that list ([replaceAll]).
///  * Rows are namespaced by `scope` (the Firebase UID, or `anon` for the
///    public catalog), so one account never sees another's data; sign-out
///    and account switches wipe the other scopes ([clearScope], [keepOnly]).
///  * No passwords, tokens or keys are stored.
///  * On web (no SQLite) every call is a quiet no-op and the app reads live.
class CustomerLocalDb {
  CustomerLocalDb({Future<Database?> Function()? database, DateTime Function()? now})
      : _database = database ?? _defaultDatabase,
        _now = now ?? DateTime.now;

  static final CustomerLocalDb instance = CustomerLocalDb();

  final Future<Database?> Function() _database;
  final DateTime Function() _now;

  static Future<Database?> _defaultDatabase() async {
    try {
      if (!await SqliteService.instance.isSupported) return null;
      return await SqliteService.instance.open();
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:open');
      return null;
    }
  }

  /// Whether a local database is available on this platform.
  Future<bool> get available async => await _database() != null;

  // ---------------------------------------------------------------------------
  // Records
  // ---------------------------------------------------------------------------

  /// Columns copied out of a server row so they can be indexed.
  @visibleForTesting
  static Map<String, Object?> projection(String kind, Map<String, dynamic> row) {
    String str(List<String> keys) {
      for (final k in keys) {
        final v = row[k];
        if (v != null && '$v'.isNotEmpty) return '$v';
      }
      return '';
    }

    double? num0(List<String> keys) {
      for (final k in keys) {
        final v = row[k];
        if (v is num) return v.toDouble();
        if (v is String) {
          final parsed = double.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    final id = str(['id', 'product_id', 'firebase_uid']);
    final title = str(['name', 'title', 'label', 'recipient_name', 'full_name', 'description', 'reason', 'id']);
    final extra = <String>[
      id,
      title,
      str(['sku']),
      str(['body', 'message']),
      str(['order_id']),
      str(['line1', 'city']),
      str(['reference', 'source']),
      // Order lines embedded in an order row: searchable by product name.
      if (row['order_items'] is List)
        for (final i in row['order_items'] as List)
          if (i is Map) '${i['product_name'] ?? ''} ${i['variant_label'] ?? ''}',
    ];
    final status = kind == LocalKind.notifications
        ? (row['read'] == true ? 'read' : 'unread')
        : (row['status'] ?? row['type'] ?? (row['is_active'] == false ? 'inactive' : null))?.toString();
    return {
      'id': id,
      'title': title.toLowerCase(),
      'search_text': extra.join(' ').toLowerCase(),
      'status': status,
      'category': str(['category_id', 'type', 'kind']).isEmpty ? null : str(['category_id', 'type', 'kind']),
      'amount': num0(['total', 'amount', 'points', 'price']),
      'sort_time': str(['created_at', 'updated_at', 'occurred_at']),
    };
  }

  /// Replaces every stored record of [kind] for [scope] with [rows] (a full,
  /// live server list). The server wins: records deleted on the server
  /// disappear here too.
  Future<void> replaceAll(String scope, String kind, List<Map<String, dynamic>> rows) async {
    final db = await _database();
    if (db == null) return;
    try {
      final savedAt = _now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.delete('customer_records', where: 'scope = ? AND kind = ?', whereArgs: [scope, kind]);
        final batch = txn.batch();
        var position = 0;
        for (final row in rows) {
          final p = projection(kind, row);
          if ((p['id'] as String).isEmpty) continue;
          batch.insert(
            'customer_records',
            {
              ...p,
              'scope': scope,
              'kind': kind,
              'position': position++,
              'json': jsonEncode(row),
              'saved_at': savedAt,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:replaceAll');
    }
  }

  /// Adds or updates single records (e.g. one more page of a paged list)
  /// without touching the others.
  Future<void> upsert(String scope, String kind, List<Map<String, dynamic>> rows) async {
    final db = await _database();
    if (db == null || rows.isEmpty) return;
    try {
      final savedAt = _now().millisecondsSinceEpoch;
      final batch = db.batch();
      for (final row in rows) {
        final p = projection(kind, row);
        if ((p['id'] as String).isEmpty) continue;
        batch.insert(
          'customer_records',
          {...p, 'scope': scope, 'kind': kind, 'json': jsonEncode(row), 'saved_at': savedAt},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:upsert');
    }
  }

  Future<void> remove(String scope, String kind, String id) async {
    final db = await _database();
    if (db == null) return;
    try {
      await db.delete('customer_records', where: 'scope = ? AND kind = ? AND id = ?', whereArgs: [scope, kind, id]);
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:remove');
    }
  }

  /// Reads a page of stored records: optional text [search] (every word must
  /// match), [status] / [category] filters, sorting and paging — all done by
  /// SQLite on indexed columns.
  Future<LocalPage> query(
    String scope,
    String kind, {
    String? search,
    String? status,
    String? category,
    LocalSort sort = LocalSort.serverOrder,
    int limit = 1000,
    int offset = 0,
  }) async {
    final db = await _database();
    if (db == null) return const LocalPage([], 0, null);
    try {
      final where = <String>['scope = ?', 'kind = ?'];
      final args = <Object?>[scope, kind];
      for (final word in (search ?? '').toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
        where.add("search_text LIKE ? ESCAPE '\\'");
        args.add('%${word.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%');
      }
      if (status != null) {
        where.add('status = ?');
        args.add(status);
      }
      if (category != null) {
        where.add('category = ?');
        args.add(category);
      }
      final orderBy = switch (sort) {
        LocalSort.newest => 'sort_time DESC, id DESC',
        LocalSort.oldest => 'sort_time ASC, id ASC',
        LocalSort.titleAsc => 'title ASC, id ASC',
        LocalSort.titleDesc => 'title DESC, id DESC',
        LocalSort.amountAsc => 'amount ASC, id ASC',
        LocalSort.amountDesc => 'amount DESC, id DESC',
        LocalSort.serverOrder => 'position ASC, sort_time DESC',
      };
      final whereSql = where.join(' AND ');
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS n, MIN(saved_at) AS t FROM customer_records WHERE $whereSql',
        args,
      );
      final total = (countRows.first['n'] as int?) ?? 0;
      final t = countRows.first['t'] as int?;
      final rows = await db.query(
        'customer_records',
        columns: ['json'],
        where: whereSql,
        whereArgs: args,
        orderBy: orderBy,
        limit: limit.clamp(1, 1000).toInt(),
        offset: offset < 0 ? 0 : offset,
      );
      return LocalPage(
        [for (final r in rows) Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map)],
        total,
        t == null ? null : DateTime.fromMillisecondsSinceEpoch(t),
      );
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:query');
      return const LocalPage([], 0, null);
    }
  }

  // ---------------------------------------------------------------------------
  // Saved server responses (OfflineReadCacheClient via LocalCache)
  // ---------------------------------------------------------------------------

  static const int maxResponsesPerScope = 600;

  Future<bool> putResponse(String scope, String key, String value) async {
    final db = await _database();
    if (db == null) return false;
    try {
      await db.insert(
        'response_cache',
        {'scope': scope, 'cache_key': key, 'value': value, 'saved_at': _now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Bounded: drop the oldest beyond the limit.
      await db.rawDelete(
        'DELETE FROM response_cache WHERE scope = ? AND cache_key IN ('
        'SELECT cache_key FROM response_cache WHERE scope = ? ORDER BY saved_at DESC LIMIT -1 OFFSET ?)',
        [scope, scope, maxResponsesPerScope],
      );
      return true;
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:putResponse');
      return false;
    }
  }

  /// `(value, savedAt)` or null. Returns null too when there is no database.
  Future<(String, DateTime)?> getResponse(String scope, String key) async {
    final db = await _database();
    if (db == null) return null;
    try {
      final rows = await db.query('response_cache',
          columns: ['value', 'saved_at'], where: 'scope = ? AND cache_key = ?', whereArgs: [scope, key], limit: 1);
      if (rows.isEmpty) return null;
      return (rows.first['value'] as String, DateTime.fromMillisecondsSinceEpoch(rows.first['saved_at'] as int));
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:getResponse');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Clearing (sign-out / account switch)
  // ---------------------------------------------------------------------------

  /// Deletes everything stored for [scope] (records and saved responses).
  Future<void> clearScope(String scope) async {
    final db = await _database();
    if (db == null) return;
    try {
      await db.delete('customer_records', where: 'scope = ?', whereArgs: [scope]);
      await db.delete('response_cache', where: 'scope = ?', whereArgs: [scope]);
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:clearScope');
    }
  }

  /// Deletes every scope except [scopes] (the signed-in account and `anon`).
  Future<void> keepOnly(Set<String> scopes) async {
    final db = await _database();
    if (db == null) return;
    try {
      final marks = List.filled(scopes.length, '?').join(', ');
      final args = scopes.toList();
      await db.delete('customer_records', where: scopes.isEmpty ? null : 'scope NOT IN ($marks)', whereArgs: scopes.isEmpty ? null : args);
      await db.delete('response_cache', where: scopes.isEmpty ? null : 'scope NOT IN ($marks)', whereArgs: scopes.isEmpty ? null : args);
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:keepOnly');
    }
  }

  // ---------------------------------------------------------------------------
  // Customer offline write queue (PendingWritesService)
  // ---------------------------------------------------------------------------

  /// All queued writes, oldest first, or null when there is no database.
  Future<List<Map<String, dynamic>>?> loadPendingWrites() async {
    final db = await _database();
    if (db == null) return null;
    try {
      final rows = await db.query('customer_pending_writes', orderBy: 'created_at ASC, id ASC');
      return [
        for (final r in rows)
          {
            'id': r['id'],
            'uid': r['uid'],
            'kind': r['kind'],
            'payload': jsonDecode(r['payload'] as String),
            'createdAt': DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int).toIso8601String(),
            'attempts': r['attempts'],
            'status': r['status'],
            'lastError': r['last_error'],
          },
      ];
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:loadPendingWrites');
      return null;
    }
  }

  /// Replaces the stored queue with [writes] (in one transaction). Returns
  /// false when there is no database (the caller keeps its fallback store).
  Future<bool> savePendingWrites(List<Map<String, dynamic>> writes) async {
    final db = await _database();
    if (db == null) return false;
    try {
      await db.transaction((txn) async {
        await txn.delete('customer_pending_writes');
        for (final w in writes) {
          await txn.insert('customer_pending_writes', {
            'id': w['id'],
            'uid': w['uid'],
            'kind': w['kind'],
            'payload': jsonEncode(w['payload']),
            'created_at': DateTime.parse(w['createdAt'] as String).millisecondsSinceEpoch,
            'attempts': w['attempts'] ?? 0,
            'status': w['status'] ?? 'pending',
            'last_error': w['lastError'],
          });
        }
      });
      return true;
    } catch (e, st) {
      AppErrors.report(e, st, 'customer_local_db:savePendingWrites');
      return false;
    }
  }
}
