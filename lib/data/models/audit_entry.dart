/// One row of the append-only audit trail (`staff_audit_logs`).
///
/// Who ([staffFirebaseUid]) did what ([action], e.g. `inventory.adjust`) to
/// which record ([entityType] / [entityId]) in which branch, and when. The
/// server fills in the actor, the branch and the time; the client only
/// describes the action.
class AuditEntry {
  final String id;
  final String staffFirebaseUid;
  final String? branchId;
  final String action;
  final String entityType;
  final String? entityId;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  const AuditEntry({
    required this.id,
    required this.staffFirebaseUid,
    required this.branchId,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.metadata,
    required this.createdAt,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final uid = j['staff_firebase_uid'];
    final action = j['action'];
    final entityType = j['entity_type'];
    final created = j['created_at'];
    if (id is! String || uid is! String || action is! String || entityType is! String || created is! String) {
      throw const FormatException('Audit record is incomplete.');
    }
    final metadata = j['metadata'];
    return AuditEntry(
      id: id,
      staffFirebaseUid: uid,
      branchId: j['branch_id'] as String?,
      action: action,
      entityType: entityType,
      entityId: j['entity_id'] as String?,
      metadata: metadata is Map ? Map<String, dynamic>.from(metadata) : const <String, dynamic>{},
      createdAt: DateTime.parse(created).toLocal(),
    );
  }
}
