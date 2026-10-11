import '../../core/services/staff_store.dart';
import '../models/delivery.dart';

// A thin read-only view over the real deliveries [StaffStore] loads from the
// database (`DeliveryRepository` / `staff_get_deliveries`). Everything is
// scoped to the branch the signed-in staff member (or owner) is viewing.
// (Was lib/data/dummy_data/dummy_deliveries.dart; renamed because it never
// held sample data any more.)

/// Real deliveries for the active branch.
List<Delivery> get kDeliveries => StaffStore.instance.deliveries;

List<Delivery> get activeDeliveries =>
    kDeliveries.where((d) => d.status.isActive).toList();

List<Delivery> get pastDeliveries =>
    kDeliveries.where((d) => !d.status.isActive).toList();
