import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/geo_utils.dart';
import '../models/delivery.dart';

/// One order eligible to become a delivery stop (`staff_list_deliverable_orders`).
class DeliverableOrder {
  final String orderId;
  final String customerName;
  final String address;
  final List<String> items;

  /// Where the customer pinned the delivery (the snapshot taken at checkout,
  /// migration 20261016000000). Null when they did not pin it, or on an older
  /// server.
  final double? latitude;
  final double? longitude;
  final String? contactPhone;

  const DeliverableOrder({
    required this.orderId,
    required this.customerName,
    required this.address,
    required this.items,
    this.latitude,
    this.longitude,
    this.contactPhone,
  });

  bool get isPinned => GeoUtils.isValidPin(latitude, longitude);

  factory DeliverableOrder.fromJson(Map<String, dynamic> j) => DeliverableOrder(
        orderId: j['order_id'] as String,
        customerName: (j['customer_name'] as String?) ?? 'Customer',
        address: (j['address'] as String?) ?? 'Address not provided',
        items: ((j['items'] as List?) ?? const []).map((e) => e.toString()).toList(),
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        contactPhone: j['contact_phone'] as String?,
      );
}

/// A registered driver of a branch (`staff_list_drivers`).
class BranchDriver {
  final String firebaseUid;
  final String fullName;
  final String? phone;
  final String? branchId;
  final String? vehicle;
  final String accountStatus; // active | inactive | suspended
  final bool isAvailable;
  final int activeRuns;

  const BranchDriver({
    required this.firebaseUid,
    required this.fullName,
    required this.accountStatus,
    required this.isAvailable,
    required this.activeRuns,
    this.phone,
    this.branchId,
    this.vehicle,
  });

  bool get isActive => accountStatus == 'active';

  factory BranchDriver.fromJson(Map<String, dynamic> j) => BranchDriver(
        firebaseUid: j['firebase_uid'] as String,
        fullName: (j['full_name'] as String?) ?? 'Driver',
        phone: j['phone'] as String?,
        branchId: j['branch_id'] as String?,
        vehicle: j['vehicle'] as String?,
        accountStatus: (j['account_status'] as String?) ?? 'active',
        isAvailable: (j['is_available'] as bool?) ?? false,
        activeRuns: (j['active_runs'] as num?)?.toInt() ?? 0,
      );
}

/// The latest shared position of a run being carried right now
/// (`staff_active_driver_positions`). Only runs that are out appear; the
/// database deletes the points when a run ends.
class DriverPosition {
  final String deliveryId;
  final String? branchId;
  final String branch;
  final String? driverUid;
  final String driverName;
  final String? driverStatus;
  final double latitude;
  final double longitude;
  final DateTime? recordedAt;

  const DriverPosition({
    required this.deliveryId,
    required this.branch,
    required this.driverName,
    required this.latitude,
    required this.longitude,
    this.branchId,
    this.driverUid,
    this.driverStatus,
    this.recordedAt,
  });

  static DriverPosition? fromJson(Map<String, dynamic> j) {
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    final id = j['delivery_id'] as String?;
    if (id == null || !GeoUtils.isValidPin(lat, lng)) return null; // never draw a made-up point
    return DriverPosition(
      deliveryId: id,
      branchId: j['branch_id'] as String?,
      branch: (j['branch'] as String?) ?? '',
      driverUid: j['driver_uid'] as String?,
      driverName: (j['driver_name'] as String?) ?? 'Driver',
      driverStatus: j['driver_status'] as String?,
      latitude: lat!,
      longitude: lng!,
      recordedAt: DateTime.tryParse(j['recorded_at'] as String? ?? '')?.toLocal(),
    );
  }
}

/// Where the customer pinned a delivery order, for the staff order screen
/// (`staff_order_delivery_pins`; own branch only for staff, all for owner).
class OrderDeliveryPin {
  final String orderId;
  final String? branchName;
  final double? branchLatitude;
  final double? branchLongitude;
  final String? address;
  final String? recipientName;
  final String? contactPhone;
  final double? latitude;
  final double? longitude;
  final double? distanceKm;

  const OrderDeliveryPin({
    required this.orderId,
    this.branchName,
    this.branchLatitude,
    this.branchLongitude,
    this.address,
    this.recipientName,
    this.contactPhone,
    this.latitude,
    this.longitude,
    this.distanceKm,
  });

  bool get isPinned => GeoUtils.isValidPin(latitude, longitude);

  factory OrderDeliveryPin.fromJson(Map<String, dynamic> j) => OrderDeliveryPin(
        orderId: j['order_id'] as String,
        branchName: j['branch_name'] as String?,
        branchLatitude: (j['branch_latitude'] as num?)?.toDouble(),
        branchLongitude: (j['branch_longitude'] as num?)?.toDouble(),
        address: j['address'] as String?,
        recipientName: j['recipient_name'] as String?,
        contactPhone: j['contact_phone'] as String?,
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        distanceKm: (j['distance_km'] as num?)?.toDouble(),
      );
}

/// One GPS point a registered driver's phone recorded for a run
/// (`driver_locations`, via `staff_get_delivery_tracking`).
class TrackPoint {
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final DateTime recordedAt;

  const TrackPoint({required this.latitude, required this.longitude, required this.recordedAt, this.accuracyM});

  static TrackPoint? fromJson(Map<String, dynamic> j) {
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    final at = DateTime.tryParse(j['recorded_at'] as String? ?? '');
    if (lat == null || lng == null || at == null) return null; // never invent a position or time
    return TrackPoint(latitude: lat, longitude: lng, recordedAt: at.toLocal(), accuracyM: (j['accuracy_m'] as num?)?.toDouble());
  }
}

/// A run plus the positions its driver shared (oldest first). An empty
/// [trail] means no position has been recorded: nothing is drawn for it.
class DeliveryTracking {
  final Delivery delivery;
  final List<TrackPoint> trail;

  const DeliveryTracking({required this.delivery, required this.trail});

  TrackPoint? get latest => trail.isEmpty ? null : trail.last;
}

/// Every staff-side call to the Delivery module backend.
///
/// Mirrors [StaffRepository]'s style: everything goes through `staff_*`
/// database functions, which enforce branch access on the server.
class DeliveryRepository {
  DeliveryRepository._();
  static final DeliveryRepository instance = DeliveryRepository._();

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

  /// Real orders at [branchId] that can be added as stops to a new delivery.
  Future<List<DeliverableOrder>> listDeliverableOrders(String? branchId) async =>
      _list(await _rpc('staff_list_deliverable_orders', {'p_branch_id': branchId}))
          .map(DeliverableOrder.fromJson)
          .toList();

  /// Creates a real delivery from a chosen set of orders (in the given,
  /// already-decided stop order) and returns the full, populated [Delivery].
  Future<Delivery> createDelivery({
    required String branchId,
    required String vehicle,
    required String riderName,
    required List<String> orderIds,
  }) async =>
      Delivery.fromJson(_map(await _rpc('staff_create_delivery', {
        'p_branch_id': branchId,
        'p_vehicle': vehicle,
        'p_rider_name': riderName,
        'p_order_ids': orderIds,
      })));

  /// Every delivery the caller may see (their branch, or every branch for
  /// an owner), newest first.
  Future<List<Delivery>> getDeliveries(String? branchId) async =>
      _list(await _rpc('staff_get_deliveries', {'p_branch_id': branchId}))
          .map(Delivery.fromJson)
          .toList();

  /// Marks a delivery as dispatched (handed off to the rider) before any
  /// stop has moved. A stop update advances status past this automatically.
  Future<Delivery> dispatchDelivery(String deliveryId) async =>
      Delivery.fromJson(_map(await _rpc('staff_dispatch_delivery', {'p_delivery_id': deliveryId})));

  /// Updates one stop's status. [status] is a [StopStatus] name
  /// ('pending' | 'enRoute' | 'delivered' | 'delayed' | 'skipped').
  /// Marking a stop 'delivered' also completes its order server-side; the
  /// parent delivery's own status is rolled forward automatically.
  Future<Delivery> updateDeliveryStop({
    required String stopId,
    required String status,
    String? issueReason,
    String? proofNote,
  }) async =>
      Delivery.fromJson(_map(await _rpc('staff_update_delivery_stop', {
        'p_stop_id': stopId,
        'p_status': status,
        'p_issue_reason': issueReason,
        'p_proof_note': proofNote,
      })));

  /// The run and the GPS points its registered driver shared while carrying
  /// it (`staff_get_delivery_tracking`; the database checks branch access).
  /// The database deletes the points when the run ends.
  Future<DeliveryTracking> getTracking(String deliveryId) async {
    final m = _map(await _rpc('staff_get_delivery_tracking', {'p_delivery_id': deliveryId}));
    return DeliveryTracking(
      delivery: Delivery.fromJson(_map(m['delivery'])),
      trail: _list(m['trail']).map(TrackPoint.fromJson).whereType<TrackPoint>().toList(),
    );
  }

  /// Cancels a whole delivery; its still-pending orders return to
  /// 'confirmed' so they can be redispatched.
  Future<Delivery> cancelDelivery(String deliveryId) async =>
      Delivery.fromJson(_map(await _rpc('staff_cancel_delivery', {'p_delivery_id': deliveryId})));

  // ---- Drivers and the live map (migration 20261010010000) ---------------------

  /// Registered drivers of [branchId] (owner: every branch when null). The
  /// database limits staff to their own branch.
  Future<List<BranchDriver>> listDrivers(String? branchId) async =>
      _list(await _rpc('staff_list_drivers', {'p_branch_id': branchId})).map(BranchDriver.fromJson).toList();

  /// Puts a registered driver on a run; they must accept it in their app.
  Future<Delivery> assignDriver(String deliveryId, String driverUid) async =>
      Delivery.fromJson(_map(await _rpc('staff_assign_driver', {'p_delivery_id': deliveryId, 'p_driver_uid': driverUid})));

  /// Takes the driver off a run they have not accepted yet.
  Future<Delivery> unassignDriver(String deliveryId, {String? reason}) async =>
      Delivery.fromJson(_map(await _rpc('staff_unassign_driver', {'p_delivery_id': deliveryId, 'p_reason': reason})));

  /// Latest position of every run being carried right now (owner: all
  /// branches when [branchId] is null; staff: their branch).
  Future<List<DriverPosition>> activeDriverPositions(String? branchId) async =>
      _list(await _rpc('staff_active_driver_positions', {'p_branch_id': branchId}))
          .map(DriverPosition.fromJson)
          .whereType<DriverPosition>()
          .toList();

  /// Every run the caller may see across their branches (owner: all
  /// branches), for the owner's all-branch live map.
  Future<List<Delivery>> getAllDeliveries() => getDeliveries(null);

  // ---- Customer pins (migration 20261016000000) ---------------------------------

  /// Where the customers pinned these delivery orders, keyed by order id.
  /// Orders of another branch (staff) and pickup orders are left out by the
  /// database. Answers an empty map on a server without the function.
  Future<Map<String, OrderDeliveryPin>> orderDeliveryPins(List<String> orderIds) async {
    if (orderIds.isEmpty) return const {};
    final ids = orderIds.length > 300 ? orderIds.sublist(0, 300) : orderIds;
    final rows = _list(await _rpc('staff_order_delivery_pins', {'p_order_ids': ids}));
    return {for (final r in rows.map(OrderDeliveryPin.fromJson)) r.orderId: r};
  }
}
