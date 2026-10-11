import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/delivery.dart';

/// The signed-in driver as the database sees them (`get_my_driver_context`).
class DriverContext {
  /// 'active' | 'not_provisioned' | 'inactive' | 'suspended'
  final String status;
  final String? fullName;
  final String? email;
  final String? phone;
  final String? branchId;
  final String? branchName;
  final String? vehicle;
  final bool isAvailable;

  const DriverContext({
    required this.status,
    this.fullName,
    this.email,
    this.phone,
    this.branchId,
    this.branchName,
    this.vehicle,
    this.isAvailable = false,
  });

  bool get isActive => status == 'active';

  factory DriverContext.fromJson(Map<String, dynamic> j) {
    final p = j['profile'] is Map ? Map<String, dynamic>.from(j['profile'] as Map) : const <String, dynamic>{};
    return DriverContext(
      status: (j['status'] as String?) ?? 'not_provisioned',
      fullName: p['full_name'] as String?,
      email: p['email'] as String?,
      phone: p['phone'] as String?,
      branchId: p['branch_id'] as String?,
      branchName: p['branch'] as String?,
      vehicle: p['vehicle'] as String?,
      isAvailable: (p['is_available'] as bool?) ?? false,
    );
  }

  String get statusMessage {
    switch (status) {
      case 'not_provisioned':
        return 'Your driver account is not set up yet. Please ask the owner to register you as a driver.';
      case 'suspended':
        return 'Your driver account has been suspended. Please contact the owner.';
      case 'inactive':
        return 'Your driver account has been deactivated. Please contact the owner.';
      default:
        return '';
    }
  }
}

/// Result of sending one location point.
class LocationAck {
  /// The point was stored (false when throttled or not tracking).
  final bool accepted;

  /// False means: stop collecting location for this run now.
  final bool tracking;

  const LocationAck({required this.accepted, required this.tracking});
}

/// Every driver-side call (migration 20261010010000_driver_module.sql).
///
/// The database decides everything that matters: whether the caller is an
/// active driver, whether the run is theirs, which status moves are allowed,
/// whether cash must be collected, and whether location is accepted. A
/// modified client gains nothing.
class DriverRepository {
  DriverRepository._();
  static final DriverRepository instance = DriverRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  static const Duration _timeout = Duration(seconds: 30);

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) async {
    try {
      return await _client.rpc(fn, params: params).timeout(_timeout);
    } on PostgrestException catch (e) {
      if (e.code == 'P0001' && e.message.trim().isNotEmpty) {
        throw AppError(AppErrorKind.unknown, e.message.trim());
      }
      throw AppErrors.from(e);
    } catch (e) {
      throw AppErrors.from(e);
    }
  }

  Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);
  List<Map<String, dynamic>> _list(dynamic v) =>
      ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  // ---- Owner: register / suspend drivers ------------------------------------

  /// Registers (or updates) a driver account. Owner only (checked by the
  /// database). [branchName] is resolved to the branch id here.
  Future<void> registerDriver({
    required String firebaseUid,
    required String fullName,
    required String email,
    required String branchName,
    String? phone,
    String? vehicle,
  }) async {
    final Map<String, dynamic>? branch;
    try {
      branch = await _client.from('branches').select('id').eq('name', branchName).maybeSingle().timeout(_timeout);
    } catch (e) {
      throw AppErrors.from(e);
    }
    if (branch == null) {
      throw const AppError(AppErrorKind.branchUnavailable, 'That branch could not be found.');
    }
    await _rpc('owner_upsert_driver', {
      'p_firebase_uid': firebaseUid,
      'p_full_name': fullName,
      'p_email': email,
      'p_branch_id': branch['id'],
      'p_phone': phone,
      'p_vehicle': vehicle,
    });
  }

  /// 'active' | 'inactive' | 'suspended'. Owner only.
  Future<void> setDriverStatus(String firebaseUid, String status) =>
      _rpc('owner_set_driver_status', {'p_firebase_uid': firebaseUid, 'p_status': status});

  // ---- Driver ----------------------------------------------------------------

  Future<DriverContext> getMyContext() async =>
      DriverContext.fromJson(_map(await _rpc('get_my_driver_context')));

  Future<DriverContext> setAvailability(bool available) async =>
      DriverContext.fromJson(_map(await _rpc('driver_set_availability', {'p_available': available})));

  /// Runs assigned to me, newest first. Finished runs only when asked; their
  /// customer addresses and phone numbers are hidden by the server.
  Future<List<Delivery>> myDeliveries({bool includeFinished = false}) async =>
      _list(await _rpc('driver_list_my_deliveries', {'p_include_finished': includeFinished}))
          .map(Delivery.fromJson)
          .toList();

  Future<Delivery> accept(String deliveryId) async => Delivery.fromJson(
      _map(await _rpc('driver_respond_assignment', {'p_delivery_id': deliveryId, 'p_action': 'accept'})));

  /// Rejecting hands the run back to the branch; nothing is returned.
  Future<void> reject(String deliveryId, String reason) async => _rpc('driver_respond_assignment',
      {'p_delivery_id': deliveryId, 'p_action': 'reject', 'p_reason': reason});

  Future<Delivery> markPickedUp(String deliveryId) async =>
      Delivery.fromJson(_map(await _rpc('driver_mark_picked_up', {'p_delivery_id': deliveryId})));

  Future<Delivery> startStop(String stopId) async =>
      Delivery.fromJson(_map(await _rpc('driver_update_stop', {'p_stop_id': stopId, 'p_status': 'enRoute'})));

  /// Proof is the recipient's name and/or a photo uploaded to the private
  /// `delivery-proofs` bucket under `<delivery id>/`. Cash on delivery needs
  /// [cashCollected] equal to the order total.
  Future<Delivery> markDelivered({
    required String stopId,
    String? recipientName,
    String? proofPhotoPath,
    String? note,
    double? cashCollected,
  }) async =>
      Delivery.fromJson(_map(await _rpc('driver_update_stop', {
        'p_stop_id': stopId,
        'p_status': 'delivered',
        'p_proof_note': note,
        'p_proof_photo_path': proofPhotoPath,
        'p_recipient_name': recipientName,
        'p_cash_collected': cashCollected,
      })));

  /// The order goes back to the branch to be re-dispatched.
  Future<Delivery> markFailed({required String stopId, required String reason, String? note}) async =>
      Delivery.fromJson(_map(await _rpc('driver_update_stop', {
        'p_stop_id': stopId,
        'p_status': 'failed',
        'p_reason': reason,
        'p_proof_note': note,
      })));

  Future<LocationAck> postLocation({
    required String deliveryId,
    required double latitude,
    required double longitude,
    double? accuracyM,
    DateTime? recordedAt,
    double? heading,
    double? speedMps,
  }) async {
    final r = _map(await _rpc('driver_post_location', {
      'p_delivery_id': deliveryId,
      'p_latitude': latitude,
      'p_longitude': longitude,
      'p_accuracy_m': accuracyM,
      'p_recorded_at': (recordedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'p_heading': heading,
      'p_speed_mps': speedMps,
    }));
    return LocationAck(
      accepted: (r['accepted'] as bool?) ?? false,
      tracking: (r['tracking'] as bool?) ?? false,
    );
  }

  /// Uploads a proof-of-delivery photo and returns the storage path to pass
  /// to [markDelivered]. The bucket is private; only the run's driver may
  /// upload and only branch staff / the owner / the driver may read.
  Future<String> uploadProofPhoto({
    required String deliveryId,
    required String stopId,
    required List<int> bytes,
  }) async {
    final path = '$deliveryId/$stopId-${DateTime.now().millisecondsSinceEpoch}.jpg';
    try {
      await _client.storage
          .from('delivery-proofs')
          .uploadBinary(path, Uint8ListConverter.from(bytes),
              fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false))
          .timeout(_timeout);
    } catch (e) {
      throw AppErrors.from(e);
    }
    return path;
  }
}

/// Small helper so callers can pass any list of bytes.
class Uint8ListConverter {
  static Uint8List from(List<int> bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}
