import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../utils/app_error.dart';
import 'sqlite/sqlite_factory.dart';

/// The ONE on-device SQLite database (staff side since version 1, customer
/// side since version 2 — see docs/ARCHITECTURE.md).
///
/// ROLE (see SECURITY.md)
///   Firebase  = who you are (authentication authority)
///   Supabase  = what you may do (business-data authority)
///   SQLite    = a local cache + the offline synchronization queue.
///
/// Nothing in this database is authoritative. Every queued operation is
/// re-validated by Supabase (RLS + the staff RPCs) with the identity that is
/// signed in at the moment it syncs, so editing the file on a rooted device
/// cannot grant access. No passwords, tokens or keys are ever stored here.
///
/// Later batches add their tables by appending a list to [migrations]; never
/// edit an earlier entry.
class SqliteService {
  SqliteService._();
  static final SqliteService instance = SqliteService._();

  static const String databaseName = 'melai_staff.db';

  /// `migrations[i]` brings the schema from version `i` to `i + 1`.
  /// Version 1 (Batch 1): staff cache, sync metadata, synchronization queue.
  /// Version 2: the customer side's local database (CustomerLocalDb):
  ///   * customer_records — the last server copy of each customer record
  ///     (products, categories, orders, loyalty, notifications, refunds,
  ///     addresses, favorites, profile), one row per record, with indexed
  ///     columns for search / sort / filter;
  ///   * response_cache — saved server responses (OfflineReadCacheClient),
  ///     moved here from shared_preferences;
  ///   * customer_pending_writes — the customer's offline write queue
  ///     (PendingWritesService), moved here from shared_preferences.
  /// Version 3: the staff side's offline working copy (StaffOfflineStore):
  ///   * staff_snapshots — last inventory / dashboard answer per branch;
  ///   * staff_order_receipts — e-receipt data per order (offline sales too);
  ///   * staff_inventory_movements — stock changes made on this device;
  ///   * staff_pending_products — products created / edited offline;
  ///   * staff_expiry_alerts — which expired batches were already announced;
  ///   * staff_local_notifications — notifications raised on this device.
  @visibleForTesting
  static const List<List<String>> migrations = [
    [
      // The server-validated staff context (profile + permissions + branch
      // access) as ONE row, so the parts can never disagree.
      '''
      CREATE TABLE staff_cache (
        firebase_uid   TEXT PRIMARY KEY,
        context_json   TEXT NOT NULL,
        account_status TEXT NOT NULL,
        role           TEXT NOT NULL,
        branch_id      TEXT,
        validated_at   INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
      )
      ''',
      // Per-person key/value state for the sync layer (e.g. last sync time).
      '''
      CREATE TABLE sync_metadata (
        scope      TEXT NOT NULL,
        key        TEXT NOT NULL,
        value      TEXT,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (scope, key)
      )
      ''',
      // The offline operation queue.
      '''
      CREATE TABLE sync_operations (
        local_operation_id TEXT PRIMARY KEY,
        staff_firebase_uid TEXT NOT NULL,
        operation_type     TEXT NOT NULL,
        entity_type        TEXT NOT NULL,
        entity_id          TEXT,
        payload            TEXT NOT NULL,
        created_at         INTEGER NOT NULL,
        retry_count        INTEGER NOT NULL DEFAULT 0,
        sync_status        TEXT NOT NULL DEFAULT 'pending'
                           CHECK (sync_status IN ('pending', 'syncing', 'synced', 'failed')),
        last_error         TEXT,
        last_attempt_at    INTEGER
      )
      ''',
      '''
      CREATE INDEX idx_sync_operations_owner
        ON sync_operations (staff_firebase_uid, sync_status, created_at)
      ''',
    ],
    // Version 2: customer side (never edit version 1 above).
    [
      '''
      CREATE TABLE customer_records (
        scope       TEXT NOT NULL,
        kind        TEXT NOT NULL,
        id          TEXT NOT NULL,
        title       TEXT NOT NULL DEFAULT '',
        search_text TEXT NOT NULL DEFAULT '',
        status      TEXT,
        category    TEXT,
        amount      REAL,
        sort_time   TEXT,
        position    INTEGER NOT NULL DEFAULT 0,
        json        TEXT NOT NULL,
        saved_at    INTEGER NOT NULL,
        PRIMARY KEY (scope, kind, id)
      )
      ''',
      'CREATE INDEX idx_records_time ON customer_records (scope, kind, sort_time)',
      'CREATE INDEX idx_records_title ON customer_records (scope, kind, title)',
      'CREATE INDEX idx_records_status ON customer_records (scope, kind, status)',
      'CREATE INDEX idx_records_category ON customer_records (scope, kind, category)',
      'CREATE INDEX idx_records_amount ON customer_records (scope, kind, amount)',
      '''
      CREATE TABLE response_cache (
        scope     TEXT NOT NULL,
        cache_key TEXT NOT NULL,
        value     TEXT NOT NULL,
        saved_at  INTEGER NOT NULL,
        PRIMARY KEY (scope, cache_key)
      )
      ''',
      'CREATE INDEX idx_response_cache_age ON response_cache (scope, saved_at)',
      '''
      CREATE TABLE customer_pending_writes (
        id         TEXT PRIMARY KEY,
        uid        TEXT NOT NULL,
        kind       TEXT NOT NULL,
        payload    TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts   INTEGER NOT NULL DEFAULT 0,
        status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'failed')),
        last_error TEXT
      )
      ''',
      'CREATE INDEX idx_customer_pending_writes_uid ON customer_pending_writes (uid, created_at)',
    ],
    // Version 3: the staff side's offline working copy (StaffOfflineStore).
    // Every table is scoped to one staff Firebase UID. Nothing here is
    // authoritative: the server re-validates every queued change.
    [
      // The last server answer for a branch's inventory / dashboard (the raw
      // RPC JSON, incl. each batch's expiration_date), read while offline.
      '''
      CREATE TABLE staff_snapshots (
        scope     TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        kind      TEXT NOT NULL,
        json      TEXT NOT NULL,
        saved_at  INTEGER NOT NULL,
        PRIMARY KEY (scope, branch_id, kind)
      )
      ''',
      // Full e-receipt data per order (items, quantities, prices, totals,
      // payment, order number, date, branch). Server orders are 'synced';
      // sales rung up offline are 'pending' until the server accepts them.
      '''
      CREATE TABLE staff_order_receipts (
        scope              TEXT NOT NULL,
        order_id           TEXT NOT NULL,
        branch_id          TEXT NOT NULL,
        json               TEXT NOT NULL,
        created_at         INTEGER NOT NULL,
        sync_status        TEXT NOT NULL DEFAULT 'synced'
                           CHECK (sync_status IN ('synced', 'pending', 'failed')),
        local_operation_id TEXT,
        server_order_id    TEXT,
        last_error         TEXT,
        saved_at           INTEGER NOT NULL,
        PRIMARY KEY (scope, order_id)
      )
      ''',
      'CREATE INDEX idx_staff_receipts_branch ON staff_order_receipts (scope, branch_id, created_at)',
      'CREATE INDEX idx_staff_receipts_op ON staff_order_receipts (scope, local_operation_id)',
      // Every stock change made on this device, as a movement (never a bare
      // "stock = stock + n"). id = the sync operation id = the server's
      // idempotency key, so the movement and the change sync together, once.
      '''
      CREATE TABLE staff_inventory_movements (
        id              TEXT PRIMARY KEY,
        scope           TEXT NOT NULL,
        branch_id       TEXT NOT NULL,
        product_id      TEXT NOT NULL,
        variant_id      TEXT NOT NULL,
        batch_id        TEXT,
        batch_code      TEXT,
        movement_type   TEXT NOT NULL CHECK (movement_type IN ('receive', 'adjust')),
        quantity_change INTEGER NOT NULL,
        assign_existing INTEGER NOT NULL DEFAULT 0,
        reason          TEXT,
        note            TEXT,
        received_date   TEXT,
        expiration_date TEXT,
        restock_threshold INTEGER,
        staff_uid       TEXT NOT NULL,
        created_at      INTEGER NOT NULL,
        sync_status     TEXT NOT NULL DEFAULT 'pending'
                        CHECK (sync_status IN ('pending', 'synced', 'failed')),
        last_error      TEXT,
        synced_at       INTEGER
      )
      ''',
      'CREATE INDEX idx_staff_movements_branch ON staff_inventory_movements (scope, branch_id, sync_status, created_at)',
      // Products created / edited offline, shown with "Pending sync" until
      // the server has them. id = the product id (made on the device for a
      // new product).
      '''
      CREATE TABLE staff_pending_products (
        scope              TEXT NOT NULL,
        id                 TEXT NOT NULL,
        operation          TEXT NOT NULL CHECK (operation IN ('create', 'update')),
        local_operation_id TEXT NOT NULL,
        json               TEXT NOT NULL,
        created_at         INTEGER NOT NULL,
        sync_status        TEXT NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'failed')),
        last_error         TEXT,
        PRIMARY KEY (scope, id)
      )
      ''',
      // One expired-stock notification per batch, ever.
      '''
      CREATE TABLE staff_expiry_alerts (
        scope            TEXT NOT NULL,
        batch_id         TEXT NOT NULL,
        expired_quantity INTEGER NOT NULL,
        notified_at      INTEGER NOT NULL,
        PRIMARY KEY (scope, batch_id)
      )
      ''',
      // Notifications raised on this device (connection lost / restored,
      // changes synced, expired stock). Shown with the server's
      // staff_notifications in the same list.
      '''
      CREATE TABLE staff_local_notifications (
        scope      TEXT NOT NULL,
        id         TEXT NOT NULL,
        category   TEXT NOT NULL,
        title      TEXT NOT NULL,
        body       TEXT NOT NULL,
        reference  TEXT,
        read       INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (scope, id)
      )
      ''',
    ],
  ];

  static int get schemaVersion => migrations.length;

  Database? _db;
  Future<Database>? _opening;

  /// False where no SQLite implementation exists (web).
  Future<bool> get isSupported async => await platformDatabaseFactory() != null;

  /// Opens (once) and returns the database. Throws an [AppError] of kind
  /// [AppErrorKind.localStorage] if SQLite is unavailable or the file cannot
  /// be opened — callers treat the cache as optional.
  Future<Database> open() {
    final existing = _db;
    if (existing != null && existing.isOpen) return Future<Database>.value(existing);
    return _opening ??= _openDefault().whenComplete(() => _opening = null);
  }

  Future<Database> _openDefault() async {
    try {
      final factory = await platformDatabaseFactory();
      if (factory == null) throw StateError('SQLite is not available on this platform.');
      final path = await platformDatabasePath(factory, databaseName);
      return _db = await openWith(factory, path);
    } catch (e) {
      if (e is AppError) rethrow;
      if (kDebugMode) debugPrint('SQLite open failed: ${e.runtimeType}');
      throw AppErrors.localStorageError();
    }
  }

  /// Opens a database with an explicit factory/path (unit tests pass an
  /// in-memory FFI factory). Applies [migrations].
  @visibleForTesting
  static Future<Database> openWith(DatabaseFactory factory, String path) {
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _migrate(db, 0, version),
        onUpgrade: (db, oldVersion, newVersion) => _migrate(db, oldVersion, newVersion),
      ),
    );
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    for (var v = from; v < to; v++) {
      for (final statement in migrations[v]) {
        await db.execute(statement);
      }
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }
}
