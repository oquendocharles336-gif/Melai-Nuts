import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Lifecycle status of an entire delivery dispatch.
enum DeliveryStatus { pending, optimized, dispatched, inTransit, completed, cancelled }

extension DeliveryStatusX on DeliveryStatus {
  String get label {
    switch (this) {
      case DeliveryStatus.pending:
        return 'Pending';
      case DeliveryStatus.optimized:
        return 'Route Planned';
      case DeliveryStatus.dispatched:
        return 'Dispatched';
      case DeliveryStatus.inTransit:
        return 'In Transit';
      case DeliveryStatus.completed:
        return 'Completed';
      case DeliveryStatus.cancelled:
        return 'Cancelled';
    }
  }

  bool get isActive => this != DeliveryStatus.completed && this != DeliveryStatus.cancelled;

  Color get color {
    switch (this) {
      case DeliveryStatus.pending:
        return AppColors.textSecondary;
      case DeliveryStatus.optimized:
        return AppColors.warning;
      case DeliveryStatus.dispatched:
        return AppColors.primary;
      case DeliveryStatus.inTransit:
        return AppColors.success;
      case DeliveryStatus.completed:
        return AppColors.success;
      case DeliveryStatus.cancelled:
        return AppColors.error;
    }
  }
}

/// Status of a single stop within a delivery route.
enum StopStatus { pending, enRoute, delivered, delayed, skipped, failed }

extension StopStatusX on StopStatus {
  String get label {
    switch (this) {
      case StopStatus.pending:
        return 'Pending';
      case StopStatus.enRoute:
        return 'En Route';
      case StopStatus.delivered:
        return 'Delivered';
      case StopStatus.delayed:
        return 'Delayed';
      case StopStatus.skipped:
        return 'Cancelled';
      case StopStatus.failed:
        return 'Failed';
    }
  }

  Color get color {
    switch (this) {
      case StopStatus.pending:
        return AppColors.textSecondary;
      case StopStatus.enRoute:
        return AppColors.warning;
      case StopStatus.delivered:
        return AppColors.success;
      case StopStatus.delayed:
        return AppColors.warning;
      case StopStatus.skipped:
        return AppColors.error;
      case StopStatus.failed:
        return AppColors.error;
    }
  }
}

/// A single stop (customer drop-off) within a [Delivery] route.
class DeliveryStop {
  final String id;
  final String customerName;
  final String address;
  final String orderId;
  final List<String> items;

  /// Position in the stop sequence (0 = first stop after branch), in the
  /// order staff added the orders — the app does no route optimization.
  final int sequenceIndex;

  /// Distance/time from the previous stop (or from the branch, for the
  /// first stop) — the server's estimate saved with the run, not real routing.
  final double distanceFromPreviousKm;
  final int travelMinutesFromPrevious;
  final String eta;

  StopStatus status;
  String? issueReason; // populated when status is delayed/skipped/failed
  String? proofNote; // optional note from the rider

  // Filled by the driver module (migration 20261010010000_driver_module.sql).
  // latitude/longitude are the pin the customer confirmed at checkout
  // (snapshot on the order, migration 20261016000000). All of these are null
  // on older servers, when the customer did not pin the address, and — for
  // drivers — once the stop or the run is finished (hidden by the server).
  final double? latitude;
  final double? longitude;
  final String? contactPhone;
  final String? customerNotes;
  final double? orderTotal;
  final String? paymentMethod; // 'cash' | 'gcash' | 'maya' | 'card'
  final String? paymentStatus; // 'pending' | 'success' | ...
  final String? recipientName;
  final String? proofPhotoPath;
  final DateTime? deliveredAt;

  DeliveryStop({
    required this.id,
    required this.customerName,
    required this.address,
    required this.orderId,
    required this.items,
    required this.sequenceIndex,
    required this.distanceFromPreviousKm,
    required this.travelMinutesFromPrevious,
    required this.eta,
    this.status = StopStatus.pending,
    this.issueReason,
    this.proofNote,
    this.latitude,
    this.longitude,
    this.contactPhone,
    this.customerNotes,
    this.orderTotal,
    this.paymentMethod,
    this.paymentStatus,
    this.recipientName,
    this.proofPhotoPath,
    this.deliveredAt,
  });

  /// True when the rider must collect cash at the door before completing.
  bool get needsCashCollection => paymentMethod == 'cash' && paymentStatus != 'success';

  bool get isFinished =>
      status == StopStatus.delivered || status == StopStatus.failed || status == StopStatus.skipped;

  /// Parses the jsonb shape returned by `staff_create_delivery` /
  /// `staff_get_deliveries` / `staff_update_delivery_stop`.
  factory DeliveryStop.fromJson(Map<String, dynamic> j) {
    return DeliveryStop(
      id: j['id'] as String,
      customerName: (j['customer_name'] as String?) ?? '—',
      address: (j['address'] as String?) ?? 'Address not provided',
      orderId: j['order_id'] as String,
      items: ((j['items'] as List?) ?? const []).map((e) => e.toString()).toList(),
      sequenceIndex: (j['sequence_index'] as num).toInt(),
      distanceFromPreviousKm: (j['distance_from_previous_km'] as num?)?.toDouble() ?? 0,
      travelMinutesFromPrevious: (j['travel_minutes_from_previous'] as num?)?.toInt() ?? 0,
      eta: (j['eta'] as String?) ?? '',
      status: _stopStatusFromName(j['status'] as String?),
      issueReason: j['issue_reason'] as String?,
      proofNote: j['proof_note'] as String?,
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      contactPhone: j['contact_phone'] as String?,
      customerNotes: j['customer_notes'] as String?,
      orderTotal: (j['order_total'] as num?)?.toDouble(),
      paymentMethod: j['payment_method'] as String?,
      paymentStatus: j['payment_status'] as String?,
      recipientName: j['recipient_name'] as String?,
      proofPhotoPath: j['proof_photo_path'] as String?,
      deliveredAt: DateTime.tryParse(j['delivered_at'] as String? ?? ''),
    );
  }
}

StopStatus _stopStatusFromName(String? name) =>
    StopStatus.values.firstWhere((s) => s.name == name, orElse: () => StopStatus.pending);

DeliveryStatus _deliveryStatusFromName(String? name) =>
    DeliveryStatus.values.firstWhere((s) => s.name == name, orElse: () => DeliveryStatus.pending);

/// A delivery dispatch: one branch, one vehicle/rider, and an ordered list
/// of stops, backed by the real `deliveries`/`delivery_stops` tables (see
/// `DeliveryRepository` for staff, `DriverRepository` for registered
/// drivers). Per-stop distance/time/ETA are a simple, honestly-labeled
/// estimate computed server-side, not real routing; live driver location is
/// recorded only while a registered driver carries the run.
class Delivery {
  final String id;
  final String branch;
  final String vehicle;
  final String riderName;
  final DateTime createdAt;
  final List<DeliveryStop> stops;
  DeliveryStatus status;

  /// Driver workflow (driver module): null when no registered driver is
  /// assigned; otherwise 'assigned' | 'accepted' | 'picked_up' |
  /// 'in_transit' | 'completed'.
  final String? driverUid;
  final String? driverStatus;
  final bool trackingActive;
  final double? branchLatitude;
  final double? branchLongitude;
  final String? branchId;
  final String? driverPhone;

  Delivery({
    required this.id,
    required this.branch,
    required this.vehicle,
    required this.riderName,
    required this.createdAt,
    required this.stops,
    this.status = DeliveryStatus.pending,
    this.driverUid,
    this.driverStatus,
    this.trackingActive = false,
    this.branchLatitude,
    this.branchLongitude,
    this.branchId,
    this.driverPhone,
  });

  /// Parses the jsonb shape returned by `staff_create_delivery` /
  /// `staff_get_deliveries` / `staff_update_delivery_stop`.
  factory Delivery.fromJson(Map<String, dynamic> j) {
    return Delivery(
      id: j['id'] as String,
      branch: (j['branch'] as String?) ?? '',
      vehicle: (j['vehicle'] as String?) ?? '',
      riderName: (j['rider_name'] as String?) ?? '',
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      status: _deliveryStatusFromName(j['status'] as String?),
      stops: ((j['stops'] as List?) ?? const [])
          .map((e) => DeliveryStop.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      driverUid: j['driver_uid'] as String?,
      driverStatus: j['driver_status'] as String?,
      trackingActive: (j['tracking_active'] as bool?) ?? false,
      branchLatitude: (j['branch_latitude'] as num?)?.toDouble(),
      branchLongitude: (j['branch_longitude'] as num?)?.toDouble(),
      branchId: j['branch_id'] as String?,
      driverPhone: j['driver_phone'] as String?,
    );
  }

  double get totalDistanceKm => stops.fold(0, (sum, s) => sum + s.distanceFromPreviousKm);
  int get totalTimeMinutes => stops.fold(0, (sum, s) => sum + s.travelMinutesFromPrevious);
  int get totalItems => stops.fold(0, (sum, s) => sum + s.items.length);
  int get deliveredCount => stops.where((s) => s.status == StopStatus.delivered).length;
  bool get isComplete => stops.isNotEmpty && stops.every((s) => s.status == StopStatus.delivered);
}
