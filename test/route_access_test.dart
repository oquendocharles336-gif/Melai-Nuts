import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/routes.dart';
import 'package:melai_nuts/data/models/staff_context.dart';
import 'package:melai_nuts/data/models/user_role.dart';

/// The client-side route guard matrix (UX / defence-in-depth; the database and
/// firestore.rules enforce the same rules on every request).
void main() {
  test('every named route has an access policy', () {
    expect(AppRoutes.routesWithoutPolicy, isEmpty);
  });

  test('guests may browse but not check out', () {
    expect(AppRoutes.canOpen(AppRoutes.login, null, signedIn: false), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.customerHome, null, signedIn: false), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.customerCheckout, null, signedIn: false), isFalse);
    expect(AppRoutes.canOpen(AppRoutes.staffPosCart, null, signedIn: false), isFalse);
  });

  test('customers never reach staff, owner or rider screens', () {
    for (final r in [AppRoutes.staffPosCart, AppRoutes.ownerUserManagement, AppRoutes.deliveryHome, AppRoutes.inventoryReceive]) {
      expect(AppRoutes.canOpen(r, UserRole.customer), isFalse, reason: r);
    }
    expect(AppRoutes.canOpen(AppRoutes.customerCheckout, UserRole.customer), isTrue);
  });

  test('staff reach the POS but not owner screens or customer checkout', () {
    expect(AppRoutes.canOpen(AppRoutes.staffPosCart, UserRole.staff), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.ownerUserManagement, UserRole.staff), isFalse);
    expect(AppRoutes.canOpen(AppRoutes.customerCheckout, UserRole.staff), isFalse);
  });

  test('the owner reaches staff and owner screens', () {
    expect(AppRoutes.canOpen(AppRoutes.staffPosCart, UserRole.owner), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.ownerUserManagement, UserRole.owner), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.deliveryCreate, UserRole.owner), isTrue);
  });

  test('riders reach only the rider portal side', () {
    expect(AppRoutes.canOpen(AppRoutes.deliveryHome, UserRole.delivery), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.deliveryHome, UserRole.staff), isFalse);
    expect(AppRoutes.canOpen(AppRoutes.staffPosCart, UserRole.delivery), isFalse);
    expect(AppRoutes.canOpen(AppRoutes.deliveryCreate, UserRole.delivery), isFalse);
  });

  test('stock receiving and refunds need their staff permission', () {
    expect(AppRoutes.permissionsFor(AppRoutes.inventoryReceive), contains(StaffPermission.manageInventory));
    expect(AppRoutes.permissionsFor(AppRoutes.staffRefunds), contains(StaffPermission.manageRefunds));
    expect(AppRoutes.permissionsFor(AppRoutes.staffPosCart), isEmpty);
  });
}
