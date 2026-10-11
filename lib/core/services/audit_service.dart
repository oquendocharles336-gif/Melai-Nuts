import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/models/audit_entry.dart';
import '../../data/models/sync_operation.dart';
import '../utils/app_error.dart';
import 'supabase_service.dart';
import 'sync_service.dart';

/// Records sensitive staff actions (inventory, products, orders, refund
/// decisions, stock transfers, payments) in the append-only
/// `staff_audit_logs` table.
///
/// HOW IT STAYS HONEST
///  * The server decides WHO did it (the verified Firebase UID), WHERE (the
///    registry's branch) and WHEN. The client only describes the action, so a
///    modified app cannot attribute an action to someone else.
///  * Normal staff cannot edit or delete audit rows: no UPDATE/DELETE grants,
///    no INSERT grant (rows only arrive through `staff_log_audit`), plus a
///    trigger that blocks changes even for privileged roles.
///  * [record] goes through the SQLite sync queue, so an action taken offline is
///    still recorded once the device reconnects. The operation id doubles as
///    the server's idempotency key, so a replay never creates a duplicate.
///
/// Never put secrets, passwords, tokens or full card/customer details in
/// [record]'s metadata — the audit trail is readable by owners.
class AuditService {
  AuditService._app()
      : this.create(
          sync: SyncService.instance,
          rpc: (fn, params) => SupabaseService.instance.client.rpc(fn, params: params),
          fetchRows: _fetchRowsFromSupabase,
        );

  @visibleForTesting
  AuditService.create({
    required this._sync,
    required this._rpc,
    required this._fetchRows,
  });

  static final AuditService instance = AuditService._app();

  /// The sync-queue operation type audit entries travel under.
  static const String operationType = 'audit.record';
  static const String entityType = 'audit_log';

  static const int _maxMetadataChars = 6000;
  static final RegExp _actionFormat = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');
  static final RegExp _entityTypeFormat = RegExp(r'^[a-z][a-z0-9_]*$');

  final SyncService _sync;
  final Future<dynamic> Function(String fn, Map<String, dynamic> params) _rpc;
  final Future<List<Map<String, dynamic>>> Function(int limit) _fetchRows;

  /// Teaches the sync service how to deliver audit entries. Call once at startup.
  void registerWithSync() => _sync.registerHandler(operationType, _deliver);

  /// Records that the signed-in staff member did [action] (dotted lower-case,
  /// e.g. `inventory.adjust`) to the [auditedEntityType] record [entityId].
  /// Durable first (SQLite), then sent as soon as the session and network allow.
  Future<SyncOperation> record({
    required String action,
    required String auditedEntityType,
    String? entityId,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) {
    if (!_actionFormat.hasMatch(action) || action.length > 80) {
      throw ArgumentError.value(action, 'action', 'must look like "inventory.adjust"');
    }
    if (!_entityTypeFormat.hasMatch(auditedEntityType) || auditedEntityType.length > 60) {
      throw ArgumentError.value(auditedEntityType, 'auditedEntityType', 'must be snake_case');
    }
    if (entityId != null && entityId.length > 128) {
      throw ArgumentError.value(entityId, 'entityId', 'is too long');
    }
    if (jsonEncode(metadata).length > _maxMetadataChars) {
      throw ArgumentError.value(metadata, 'metadata', 'is too large');
    }
    return _sync.enqueue(
      operationType: operationType,
      entityType: entityType,
      entityId: entityId,
      payload: <String, dynamic>{
        'action': action,
        'entity_type': auditedEntityType,
        'entity_id': entityId,
        'metadata': metadata,
      },
    );
  }

  Future<void> _deliver(SyncOperation op) async {
    final p = op.payload;
    try {
      await AppErrors.guard<dynamic>(
        () => _rpc('staff_log_audit', <String, dynamic>{
          'p_action': p['action'],
          'p_entity_type': p['entity_type'],
          'p_entity_id': p['entity_id'],
          'p_metadata': p['metadata'] ?? <String, dynamic>{},
          'p_client_operation_id': op.localOperationId,
        }),
        timeout: AppErrors.rpcTimeout,
      );
    } catch (e) {
      final error = AppErrors.from(e);
      if (error.kind == AppErrorKind.invalidData || error.kind == AppErrorKind.permissionDenied) {
        throw SyncRejectedException(error.message);
      }
      rethrow;
    }
  }

  /// The signed-in staff member's own recent audit entries (owners see every
  /// staff member's). Row Level Security decides what comes back.
  Future<List<AuditEntry>> fetchRecent({int limit = 50}) async {
    final capped = limit.clamp(1, 200).toInt();
    final rows = await AppErrors.guard<List<Map<String, dynamic>>>(
      () => _fetchRows(capped),
    );
    try {
      return rows.map(AuditEntry.fromJson).toList(growable: false);
    } on FormatException {
      throw const AppError(
        AppErrorKind.invalidData,
        'We received some unexpected data. Please try again.',
      );
    }
  }

  static Future<List<Map<String, dynamic>>> _fetchRowsFromSupabase(int limit) async {
    final data = await SupabaseService.instance.client
        .from('staff_audit_logs')
        .select()
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(data);
  }
}
