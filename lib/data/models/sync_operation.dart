import 'dart:convert';

/// Where an offline operation stands.
///
///  * [pending]  waiting for a connection / its turn
///  * [syncing]  being sent right now (a crash mid-send is recovered to pending)
///  * [synced]   the server accepted it
///  * [failed]   the server refused it, or retries ran out; needs a person to
///               retry or discard it — never silently dropped
enum SyncStatus {
  pending,
  syncing,
  synced,
  failed;

  static SyncStatus parse(Object? value) {
    for (final s in SyncStatus.values) {
      if (s.name == value) return s;
    }
    throw FormatException('Unknown sync status "$value".');
  }
}

/// One operation waiting to be sent to Supabase, owned by exactly one staff
/// member (their Firebase UID). Later batches define the concrete
/// [operationType] / [entityType] values (e.g. `inventory.adjust`) and register
/// a handler for each with `SyncService`.
class SyncOperation {
  final String localOperationId;
  final String staffFirebaseUid;
  final String operationType;
  final String entityType;
  final String? entityId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int retryCount;
  final SyncStatus syncStatus;
  final String? lastError;
  final DateTime? lastAttemptAt;

  const SyncOperation({
    required this.localOperationId,
    required this.staffFirebaseUid,
    required this.operationType,
    required this.entityType,
    required this.payload,
    required this.createdAt,
    this.entityId,
    this.retryCount = 0,
    this.syncStatus = SyncStatus.pending,
    this.lastError,
    this.lastAttemptAt,
  });

  factory SyncOperation.fromMap(Map<String, Object?> row) {
    final payload = jsonDecode(row['payload'] as String);
    if (payload is! Map) throw const FormatException('Operation payload is not an object.');
    final attempt = row['last_attempt_at'] as int?;
    return SyncOperation(
      localOperationId: row['local_operation_id'] as String,
      staffFirebaseUid: row['staff_firebase_uid'] as String,
      operationType: row['operation_type'] as String,
      entityType: row['entity_type'] as String,
      entityId: row['entity_id'] as String?,
      payload: Map<String, dynamic>.from(payload),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      retryCount: (row['retry_count'] as int?) ?? 0,
      syncStatus: SyncStatus.parse(row['sync_status']),
      lastError: row['last_error'] as String?,
      lastAttemptAt: attempt == null ? null : DateTime.fromMillisecondsSinceEpoch(attempt),
    );
  }

  Map<String, Object?> toMap() => {
        'local_operation_id': localOperationId,
        'staff_firebase_uid': staffFirebaseUid,
        'operation_type': operationType,
        'entity_type': entityType,
        'entity_id': entityId,
        'payload': jsonEncode(payload),
        'created_at': createdAt.millisecondsSinceEpoch,
        'retry_count': retryCount,
        'sync_status': syncStatus.name,
        'last_error': lastError,
        'last_attempt_at': lastAttemptAt?.millisecondsSinceEpoch,
      };
}
