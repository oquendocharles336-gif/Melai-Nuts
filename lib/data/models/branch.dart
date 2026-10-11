/// A physical Melai Nuts branch, backed by the `branches` table.
///
/// This is real, staff/owner-managed data — there is no fabricated branch
/// anywhere in the customer app. When a customer picks a branch, the
/// product catalog's stock/availability is re-scoped to this branch's
/// `branch_inventory` rows (see `ProductsRepository.loadCatalog`).
class Branch {
  final String id;
  final String name;
  final String address;
  final String? contactPhone;
  final String? operatingHours;

  /// Operating status shown to customers — `false` means "temporarily
  /// closed", not deleted.
  final bool isActive;
  final bool supportsDelivery;
  final bool supportsPickup;
  final double deliveryFee;

  /// A warehouse only holds stock (migration 20261022000000): it never takes
  /// orders and is hidden from customers; staff transfer stock from it.
  final bool isWarehouse;

  /// Branches a customer can pick: open for pickup or delivery, not a warehouse.
  bool get servesCustomers => !isWarehouse && (supportsPickup || supportsDelivery);

  /// Map position of the branch (`branches.latitude/longitude`); null until
  /// the owner sets it. Used to center the customer's map picker and to warn
  /// about pins far away from the branch.
  final double? latitude;
  final double? longitude;

  const Branch({
    required this.id,
    required this.name,
    required this.address,
    required this.isActive,
    required this.supportsDelivery,
    required this.supportsPickup,
    required this.deliveryFee,
    this.isWarehouse = false,
    this.contactPhone,
    this.operatingHours,
    this.latitude,
    this.longitude,
  });

  factory Branch.fromRow(Map<String, dynamic> row) {
    return Branch(
      id: row['id'] as String,
      name: row['name'] as String,
      address: (row['address'] as String?) ?? '',
      contactPhone: row['contact_phone'] as String?,
      operatingHours: row['operating_hours'] as String?,
      isActive: (row['is_active'] as bool?) ?? true,
      supportsDelivery: (row['supports_delivery'] as bool?) ?? true,
      supportsPickup: (row['supports_pickup'] as bool?) ?? true,
      deliveryFee: (row['delivery_fee'] as num?)?.toDouble() ?? 0,
      isWarehouse: (row['is_warehouse'] as bool?) ?? false,
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
    );
  }
}
