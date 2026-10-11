import 'package:flutter/material.dart';

import '../data/models/user_role.dart';
import 'route_guard.dart';
import '../data/models/product.dart';
import '../data/catalog_store.dart';
import '../data/models/order.dart';
import '../features/auth/screens/splash_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/forgot_password_screen.dart';
import '../features/auth/screens/reset_password_screen.dart';
import '../features/auth/screens/password_reset_success_screen.dart';
import '../features/auth/screens/security_login_screen.dart';
import '../features/customer/screens/customer_portal_screen.dart';
import '../features/customer/screens/customer_home_screen.dart';
import '../features/customer/screens/product_catalog_screen.dart';
import '../features/customer/screens/product_categories_screen.dart';
import '../features/customer/screens/product_list_screen.dart';
import '../features/customer/screens/product_details_screen.dart';
import '../features/customer/screens/search_results_screen.dart';
import '../features/customer/screens/cart_screen.dart';
import '../features/customer/screens/checkout_screen.dart';
import '../features/customer/screens/order_confirmation_screen.dart';
import '../features/customer/screens/order_history_screen.dart';
import '../features/customer/screens/order_details_screen.dart';
import '../features/customer/screens/repeat_order_screen.dart';
import '../features/customer/screens/order_tracking_screen.dart';
import '../features/customer/screens/customer_profile_screen.dart';
import '../features/customer/screens/edit_profile_screen.dart';
import '../features/customer/screens/saved_addresses_screen.dart';
import '../features/customer/screens/loyalty_dashboard_screen.dart';
import '../features/customer/screens/rfid_tap_screen.dart';
import '../features/customer/screens/loyalty_history_screen.dart';
import '../features/customer/screens/redeem_rewards_screen.dart';
import '../features/customer/screens/loyalty_transaction_screen.dart';
import '../features/customer/screens/redemption_success_screen.dart';
import '../features/staff/screens/staff_portal_screen.dart';
import '../features/staff/screens/pos_flow_screens.dart';
import '../features/staff/screens/staff_transactions_screen.dart';
import '../features/staff/screens/staff_extra_screens.dart';
import '../features/inventory/screens/inventory_dashboard_screen.dart';
import '../features/inventory/screens/inventory_list_screen.dart';
import '../features/inventory/screens/branch_inventory_screen.dart';
import '../features/inventory/screens/inventory_product_details_screen.dart';
import '../features/inventory/screens/fefo_screen.dart';
import '../features/inventory/screens/batch_details_screen.dart';
import '../features/inventory/screens/low_stock_screen.dart';
import '../features/inventory/screens/inventory_adjustment_screen.dart';
import '../features/inventory/screens/inventory_adjustment_success_screen.dart';
import '../features/inventory/screens/add_inventory_screen.dart';
import '../features/inventory/screens/receive_batch_screen.dart';
import '../features/inventory/screens/stock_transfers_screen.dart';
import '../features/staff/screens/staff_refunds_screen.dart';
import '../data/models/inventory_item.dart';
import '../data/models/staff_context.dart';
import '../data/models/staff_models.dart';
import '../data/models/inventory_batch.dart';
import '../features/products/screens/product_management_screen.dart';
import '../features/products/screens/product_list_screen.dart' as pm;
import '../features/products/screens/product_details_screen.dart' as pm;
import '../features/products/screens/add_product_screen.dart';
import '../features/products/screens/edit_product_screen.dart';
import '../features/products/screens/product_variants_screen.dart';
import '../features/products/screens/product_pricing_screen.dart';
import '../features/products/screens/product_performance_screen.dart';
import '../features/owner/screens/owner_portal_screen.dart';
import '../features/owner/screens/user_management_screen.dart';
import '../features/owner/screens/owner_dashboard_screen.dart';
import '../features/owner/screens/business_overview_screen.dart';
import '../features/owner/screens/sales_overview_screen.dart';
import '../features/owner/screens/sales_analytics_screen.dart';
import '../features/owner/screens/sales_trends_screen.dart';
import '../features/owner/screens/branch_comparison_screen.dart';
import '../features/owner/screens/branch_performance_screen.dart';
import '../features/owner/screens/product_performance_screen.dart';
import '../features/delivery/screens/driver_portal_screen.dart';
import '../features/delivery/screens/delivery_dashboard_screen.dart';
import '../features/delivery/screens/create_delivery_screen.dart';
import '../features/delivery/screens/route_optimization_screen.dart';
import '../features/delivery/screens/route_map_screen.dart';
import '../features/delivery/screens/delivery_manifest_screen.dart';
import '../features/delivery/screens/delivery_details_screen.dart';
import '../features/delivery/screens/delivery_history_screen.dart';
import '../features/delivery/screens/driver_directory_screen.dart';
import '../features/delivery/screens/live_delivery_map_screen.dart';
import '../features/delivery/screens/assigned_deliveries_screen.dart';
import '../features/delivery/screens/active_delivery_screen.dart';
import '../features/delivery/screens/delivery_route_screen.dart';
import '../features/delivery/screens/gps_tracking_screen.dart';
import '../features/delivery/screens/route_details_screen.dart';
import '../features/delivery/screens/delivery_progress_screen.dart';
import '../features/delivery/screens/next_stop_screen.dart';
import '../features/delivery/screens/delivery_confirmation_screen.dart';
import '../features/delivery/screens/completed_delivery_screen.dart';
import '../features/delivery/screens/delayed_delivery_screen.dart';
import '../features/delivery/screens/cancelled_delivery_screen.dart';
import '../data/models/delivery.dart';
import '../data/models/payment.dart';
import '../data/models/refund.dart';
import '../features/payments/screens/payment_screen.dart';
import '../features/payments/screens/payment_status_screen.dart';
import '../features/refunds/screens/refund_request_screen.dart';
import '../features/refunds/screens/refund_history_screen.dart';
import '../features/refunds/screens/refund_processing_screen.dart';
import '../data/models/notification_item.dart';
import '../features/notifications/screens/notification_center_screen.dart';
import '../features/notifications/screens/notification_detail_screen.dart';
import '../features/notifications/screens/notification_settings_screen.dart';
import '../features/settings/screens/settings_screen.dart';
import '../features/settings/screens/security_screen.dart';
import '../features/settings/screens/branch_settings_screen.dart';
import '../features/settings/screens/logout_confirmation_screen.dart';
import '../features/settings/screens/logout_success_screen.dart';
import '../core/utils/app_error.dart';

/// Centralized route names. Keep every navigable screen registered here so
/// navigation logic never has to hard-code route strings in feature code.
class AppRoutes {
  AppRoutes._();

  static const String splash = '/';
  // Single sign-in / create-account screen shared by every role (customer,
  // staff, owner, delivery). Kept as one route so there's exactly one login
  // destination in the app.
  static const String login = '/login';
  static const String forgotPassword = '/forgot-password';
  static const String resetPassword = '/reset-password';
  static const String resetSuccess = '/reset-success';
  static const String security = '/security';

  static const String customerHome = '/customer';
  static const String staffHome = '/staff';
  static const String ownerHome = '/owner';
  static const String deliveryHome = '/delivery';

  // Delivery management screens (lib/features/delivery/): owner and branch
  // staff create, assign, dispatch, track and close runs here — the admin
  // website has no delivery function.
  static const String deliveryDashboard = '/delivery/dashboard';
  static const String deliveryCreate = '/delivery/create';
  static const String routeOptimization = '/delivery/route-optimization';
  static const String routeMap = '/delivery/route-map';
  static const String deliveryManifest = '/delivery/manifest';
  static const String deliveryDetails = '/delivery/details';
  static const String deliveryHistory = '/delivery/history';
  static const String deliveryLiveMap = '/delivery/live-map';
  static const String deliveryDrivers = '/delivery/drivers';

  // Delivery Personnel (rider) flow screens.
  static const String deliveryAssigned = '/delivery/assigned';
  static const String deliveryActive = '/delivery/active';
  static const String deliveryRoute = '/delivery/route';
  static const String gpsTracking = '/delivery/gps-tracking';
  static const String deliveryRouteDetails = '/delivery/route-details';
  static const String deliveryProgress = '/delivery/progress';
  static const String deliveryNextStop = '/delivery/next-stop';
  static const String deliveryConfirmation = '/delivery/confirmation';
  static const String deliveryCompleted = '/delivery/completed';
  static const String deliveryDelayed = '/delivery/delayed';
  static const String deliveryCancelled = '/delivery/cancelled';

  // Customer feature screens (see lib/features/customer/screens/).
  // Screens that take arguments (product/category/order) expose sensible
  // defaults so they also work when reached via Navigator.pushNamed; normal
  // in-app navigation instead pushes them directly with real data.
  static const String customerStore = '/customer/store';
  static const String customerCatalog = '/customer/catalog';
  static const String customerCategories = '/customer/categories';
  static const String customerProductList = '/customer/product-list';
  static const String customerProductDetails = '/customer/product-details';
  static const String customerSearch = '/customer/search';
  static const String customerCart = '/customer/cart';
  static const String customerCheckout = '/customer/checkout';
  static const String customerOrderConfirmation = '/customer/order-confirmation';
  static const String customerOrderHistory = '/customer/order-history';
  static const String customerOrderDetails = '/customer/order-details';
  static const String customerRepeatOrder = '/customer/repeat-order';
  static const String customerOrderTracking = '/customer/order-tracking';
  static const String customerProfile = '/customer/profile';
  static const String customerEditProfile = '/customer/edit-profile';
  static const String customerSavedAddresses = '/customer/addresses';

  static const String customerLoyaltyDashboard = '/customer/loyalty';
  static const String customerRfidTap = '/customer/loyalty/rfid-tap';
  static const String customerLoyaltyTransaction = '/customer/loyalty/transaction';
  static const String customerLoyaltyHistory = '/customer/loyalty/history';
  static const String customerRedeemRewards = '/customer/loyalty/redeem';
  static const String customerRedemptionSuccess = '/customer/loyalty/redemption-success';

  // Payments feature screens (lib/features/payments/).
  static const String paymentPay = '/payments/pay';
  static const String paymentStatus = '/payments/status';

  // Refunds feature screens (lib/features/refunds/).
  static const String customerRefundRequest = '/refunds/request';
  static const String customerRefundHistory = '/refunds/history';
  static const String refundProcessing = '/refunds/processing';

  // Notifications feature screens (lib/features/notifications/) — shared
  // across all roles.
  static const String notificationCenter = '/notifications';
  static const String notificationDetail = '/notifications/detail';
  static const String notificationSettings = '/notifications/settings';

  // Settings feature screens (lib/features/settings/) — shared across all
  // roles.
  static const String appSettings = '/settings';
  static const String accountSecurity = '/settings/security';
  static const String branchSettings = '/settings/branch';
  static const String logoutConfirmation = '/settings/logout';
  static const String logoutSuccess = '/settings/logout-success';

  static String homeFor(UserRole role) {
    switch (role) {
      case UserRole.customer:
        return customerHome;
      case UserRole.staff:
        return staffHome;
      case UserRole.owner:
        return ownerHome;
      case UserRole.delivery:
        return deliveryHome;
    }
  }

  // Staff feature screens
  static const String staffPosCart = '/staff/pos/cart';
  static const String staffPosPayment = '/staff/pos/payment';
  static const String staffPosCashInput = '/staff/pos/cash-input';
  static const String staffPosProcessing = '/staff/pos/processing';
  static const String staffPosReceipt = '/staff/pos/receipt';
  static const String staffPosFailed = '/staff/pos/failed';
  static const String staffTransactionDetails = '/staff/transactions/details';
  static const String staffNotifications = '/staff/notifications';
  static const String staffProfile = '/staff/profile';

  // Staff Inventory (FEFO) feature screens.
  // Inventory & FEFO feature screens (lib/features/inventory/).
  static const String inventoryDashboard = '/inventory';
  static const String inventoryList = '/inventory/list';
  static const String inventoryBranch = '/inventory/branch';
  static const String inventoryProductDetails = '/inventory/product-details';
  static const String inventoryFefo = '/inventory/fefo';
  static const String inventoryBatchDetails = '/inventory/batch-details';
  static const String inventoryLowStock = '/inventory/low-stock';
  static const String inventoryAdjustment = '/inventory/adjust';
  static const String inventoryAdjustmentSuccess = '/inventory/adjust-success';
  static const String inventoryAdd = '/inventory/add';
  static const String inventoryReceive = '/inventory/receive';
  static const String inventoryTransfers = '/inventory/transfers';
  static const String staffRefunds = '/staff/refunds';

  // Product Management & Pricing feature screens (lib/features/products/).
  static const String productManagement = '/products';
  static const String productList = '/products/list';
  static const String productDetails = '/products/details';
  static const String productAdd = '/products/add';
  static const String productEdit = '/products/edit';
  static const String productVariants = '/products/variants';
  static const String productPricing = '/products/pricing';
  static const String productPerformance = '/products/performance';


  static const String ownerUserManagement = '/owner/users';

  // Owner module screens (lib/features/owner/).
  static const String ownerDashboard = '/owner/dashboard';
  static const String ownerBusinessOverview = '/owner/business-overview';
  static const String ownerSalesOverview = '/owner/sales-overview';
  static const String ownerSalesAnalytics = '/owner/sales-analytics';
  static const String ownerSalesTrends = '/owner/sales-trends';
  static const String ownerBranchComparison = '/owner/branch-comparison';
  static const String ownerBranchPerformance = '/owner/branch-performance';
  static const String ownerProductPerformance = '/owner/product-performance';


  // ---------------------------------------------------------------------
  // Access policy (client-side gate — see RouteGuard for why this is only
  // defence-in-depth; the real enforcement is firestore.rules).
  //
  // Every named route MUST appear in [_policy]. Anything not listed is
  // rejected in debug builds (assert) and, in release, requires a signed-in
  // user of any role rather than being silently public.
  // ---------------------------------------------------------------------
  static const _Access _public = _Access.public();
  static const _Access _anySignedIn = _Access(null);
  static const _Access _customerOnly = _Access({UserRole.customer});
  // Public catalog browsing: guests and customers only.
  static const _Access _customerBrowse = _Access({UserRole.customer}, guest: true);
  // Owner is a superset of staff (matches firestore.rules); the Owner portal
  // also links into the inventory screens.
  static const _Access _staff = _Access({UserRole.staff, UserRole.owner});
  // Staff screens that only make sense with a management permission. Owners
  // hold every permission. UX gate only: the staff RPCs enforce the same rule.
  static const _Access _staffManageInventory = _Access(
    {UserRole.staff, UserRole.owner},
    permissions: {StaffPermission.manageInventory},
  );
  static const _Access _staffManageRefunds = _Access(
    {UserRole.staff, UserRole.owner},
    permissions: {StaffPermission.manageRefunds},
  );
  static const _Access _owner = _Access({UserRole.owner});
  // Delivery screens shared by riders and the delivery management of the
  // owner and branch staff (the staff_* delivery RPCs check the branch).
  static const _Access _rider = _Access({UserRole.delivery, UserRole.staff, UserRole.owner});
  static const _Access _riderOnly = _Access({UserRole.delivery});

  static const Map<String, _Access> _policy = {
    splash: _public,
    login: _public,
    forgotPassword: _public,
    logoutSuccess: _public,
    resetPassword: _anySignedIn,
    resetSuccess: _anySignedIn,
    security: _anySignedIn,
    notificationCenter: _anySignedIn,
    notificationDetail: _anySignedIn,
    notificationSettings: _anySignedIn,
    appSettings: _anySignedIn,
    accountSecurity: _anySignedIn,
    branchSettings: _anySignedIn,
    logoutConfirmation: _anySignedIn,

    customerHome: _customerBrowse,
    customerStore: _customerBrowse,
    customerCatalog: _customerBrowse,
    customerCategories: _customerBrowse,
    customerProductList: _customerBrowse,
    customerProductDetails: _customerBrowse,
    customerSearch: _customerBrowse,
    customerCart: _customerBrowse,

    customerCheckout: _customerOnly,
    customerOrderConfirmation: _customerOnly,
    customerOrderHistory: _customerOnly,
    customerOrderDetails: _customerOnly,
    customerRepeatOrder: _customerOnly,
    customerOrderTracking: _customerOnly,
    customerProfile: _customerOnly,
    customerEditProfile: _customerOnly,
    customerSavedAddresses: _customerOnly,
    customerLoyaltyDashboard: _customerOnly,
    customerRfidTap: _customerOnly,
    customerLoyaltyTransaction: _customerOnly,
    customerLoyaltyHistory: _customerOnly,
    customerRedeemRewards: _customerOnly,
    customerRedemptionSuccess: _customerOnly,
    paymentPay: _customerOnly,
    paymentStatus: _customerOnly,
    customerRefundRequest: _customerOnly,
    customerRefundHistory: _customerOnly,
    refundProcessing: _customerOnly,

    staffHome: _staff,
    staffPosCart: _staff,
    staffPosPayment: _staff,
    staffPosCashInput: _staff,
    staffPosProcessing: _staff,
    staffPosReceipt: _staff,
    staffPosFailed: _staff,
    staffTransactionDetails: _staff,
    staffNotifications: _staff,
    staffProfile: _staff,
    inventoryDashboard: _staff,
    inventoryList: _staff,
    inventoryBranch: _staff,
    inventoryProductDetails: _staff,
    inventoryFefo: _staff,
    inventoryBatchDetails: _staff,
    inventoryLowStock: _staff,
    inventoryAdjustment: _staffManageInventory,
    inventoryAdjustmentSuccess: _staffManageInventory,
    inventoryAdd: _staffManageInventory,
    inventoryReceive: _staffManageInventory,
    inventoryTransfers: _staff,
    staffRefunds: _staffManageRefunds,

    ownerHome: _owner,
    ownerUserManagement: _owner,
    ownerDashboard: _owner,
    ownerBusinessOverview: _owner,
    ownerSalesOverview: _owner,
    ownerSalesAnalytics: _owner,
    ownerSalesTrends: _owner,
    ownerBranchComparison: _owner,
    ownerBranchPerformance: _owner,
    ownerProductPerformance: _owner,
    productManagement: _owner,
    productList: _owner,
    productDetails: _owner,
    productAdd: _owner,
    productEdit: _owner,
    productVariants: _owner,
    productPricing: _owner,
    productPerformance: _owner,
    // Owner (all branches) and branch staff (own branch): the database scopes
    // every delivery RPC to the branches the account may see.
    deliveryDashboard: _staff,
    deliveryCreate: _staff,
    deliveryHistory: _staff,
    deliveryLiveMap: _staff,
    deliveryDrivers: _staff,

    deliveryHome: _riderOnly,
    deliveryAssigned: _rider,
    routeOptimization: _rider,
    routeMap: _rider,
    deliveryManifest: _rider,
    deliveryDetails: _rider,
    deliveryActive: _rider,
    deliveryRoute: _rider,
    gpsTracking: _rider,
    deliveryRouteDetails: _rider,
    deliveryProgress: _rider,
    deliveryNextStop: _rider,
    deliveryConfirmation: _rider,
    deliveryCompleted: _rider,
    deliveryDelayed: _rider,
    deliveryCancelled: _rider,
  };

  /// Test seam: may [role] open [route]? (`signedIn: false` = a guest.)
  /// Mirrors [_guard] + [RouteGuard] exactly; UX gate only, the database and
  /// firestore.rules enforce the real rules.
  @visibleForTesting
  static bool canOpen(String route, UserRole? role, {bool signedIn = true}) {
    final access = _policy[route] ?? _anySignedIn;
    if (access.isPublic) return true;
    if (!signedIn || role == null) return access.guest;
    return RouteGuard.roleAllowed(role, access.roles);
  }

  /// Test seam: named routes that have no access policy (must be empty).
  @visibleForTesting
  static List<String> get routesWithoutPolicy =>
      _rawRoutes.keys.where((r) => !_policy.containsKey(r)).toList();

  /// Test seam: permissions a staff member needs for [route].
  @visibleForTesting
  static Set<String> permissionsFor(String route) => (_policy[route] ?? _anySignedIn).permissions;

  static WidgetBuilder _guard(String? name, WidgetBuilder builder) {
    final access = _policy[name];
    assert(access != null, 'No access policy defined for route "$name".');
    final effective = access ?? _anySignedIn;
    if (effective.isPublic) return builder;
    return (context) => RouteGuard(
          allowedRoles: effective.roles,
          allowGuest: effective.guest,
          requiredPermissions: effective.permissions,
          builder: builder,
        );
  }

  /// All static routes, each wrapped with its access policy.
  static Map<String, WidgetBuilder> get routes => {
        for (final e in _rawRoutes.entries) e.key: _guard(e.key, e.value),
      };

  /// Dynamic route generator for screens that require complex objects as
  /// arguments (e.g. Product, Order). Wrapped with the same access policy;
  /// invalid/mismatched arguments show a safe screen instead of crashing.
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final Route<dynamic>? raw;
    try {
      raw = _rawOnGenerateRoute(settings);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'routes:447');
      return MaterialPageRoute<dynamic>(
        settings: settings,
        builder: (_) => const UnavailableRouteScreen(),
      );
    }
    if (raw is! MaterialPageRoute) return raw;
    final inner = raw.builder;
    return MaterialPageRoute<dynamic>(
      settings: settings,
      builder: _guard(settings.name, inner),
    );
  }

  static Map<String, WidgetBuilder> get _rawRoutes => {
    splash: (_) => const SplashScreen(),
    login: (_) => const LoginScreen(),
    forgotPassword: (_) => const ForgotPasswordScreen(),
    resetPassword: (_) => const ResetPasswordScreen(),
    resetSuccess: (_) => const PasswordResetSuccessScreen(),
    security: (_) => const SecurityLoginScreen(),
    customerHome: (_) => const CustomerPortalScreen(),
    staffHome: (_) => const StaffPortalScreen(),
    ownerHome: (_) => const OwnerPortalScreen(),
    // Registered drivers (database `drivers` table). The older staff-session
    // based DeliveryPortalScreen could not load anything for a rider.
    deliveryHome: (_) => const DriverPortalScreen(),

    deliveryDashboard: (_) => const DeliveryDashboardScreen(),
    deliveryCreate: (_) => const CreateDeliveryScreen(),
    deliveryHistory: (_) => const DeliveryHistoryScreen(),
    deliveryLiveMap: (_) => const LiveDeliveryMapScreen(),
    deliveryDrivers: (_) => const DriverDirectoryScreen(),
    deliveryAssigned: (_) => const AssignedDeliveriesScreen(),
    // NOTE: deliveryActive, deliveryRoute, gpsTracking, deliveryRouteDetails,
    // deliveryProgress, deliveryNextStop, deliveryConfirmation,
    // deliveryCompleted, deliveryDelayed, and deliveryCancelled all take a
    // Delivery (and sometimes a DeliveryStop) argument and are handled
    // exclusively in onGenerateRoute below (see the earlier note on route
    // shadowing).
    // NOTE: routeOptimization, routeMap, deliveryManifest, and
    // deliveryDetails all take a Delivery argument and are handled
    // exclusively in onGenerateRoute below (see the earlier note on route
    // shadowing).

    // Customer feature screens — reachable directly for testing/deep-links.
    customerStore: (_) => const CustomerHomeScreen(),
    customerCatalog: (_) => const ProductCatalogScreen(),
    customerCategories: (_) => const ProductCategoriesScreen(),
    // NOTE: customerProductList, customerProductDetails,
    // customerOrderDetails, and customerRepeatOrder are intentionally NOT
    // registered here — they take optional arguments and are handled
    // exclusively in onGenerateRoute below (see note above the inventory
    // routes for why registering them in both places is a bug).
    customerSearch: (_) => const SearchResultsScreen(),
    customerCart: (_) => const CartScreen(),
    customerCheckout: (_) => const CheckoutScreen(),
    // customerOrderConfirmation is NOT registered here — it now requires a
    // real Order argument (built at checkout time) and is only reachable
    // via the direct MaterialPageRoute push from CheckoutScreen.
    customerOrderHistory: (_) => const OrderHistoryScreen(),
    customerProfile: (_) => const CustomerProfileScreen(),
    customerEditProfile: (_) => const EditProfileScreen(),
    customerSavedAddresses: (_) => const SavedAddressesScreen(),

    customerLoyaltyDashboard: (_) => const LoyaltyDashboardScreen(),
    customerRfidTap: (_) => const RfidTapScreen(),
    customerLoyaltyHistory: (_) => const LoyaltyHistoryScreen(),
    customerRedeemRewards: (_) => const RedeemRewardsScreen(),
    customerRefundHistory: (_) => const RefundHistoryScreen(),
    notificationCenter: (_) => const NotificationCenterScreen(),
    notificationSettings: (_) => const NotificationSettingsScreen(),
    appSettings: (_) => const SettingsScreen(),
    accountSecurity: (_) => const SecurityScreen(),
    branchSettings: (_) => const BranchSettingsScreen(),
    logoutConfirmation: (_) => const LogoutConfirmationScreen(),
    logoutSuccess: (_) => const LogoutSuccessScreen(),
    // NOTE: paymentPay, paymentStatus, customerRefundRequest,
    // refundProcessing, and notificationDetail all take arguments and are
    // handled exclusively in onGenerateRoute below (see the earlier note on
    // route shadowing).

    staffPosFailed: (_) => const PosFailedScreen(),
    staffNotifications: (_) => const StaffNotificationsScreen(),
    staffProfile: (_) => const StaffProfileScreen(),

    inventoryDashboard: (_) => const InventoryDashboardScreen(),
    inventoryList: (_) => const InventoryListScreen(),
    inventoryLowStock: (_) => const LowStockScreen(),
    inventoryAdd: (_) => const AddInventoryScreen(),
    inventoryTransfers: (_) => const StockTransfersScreen(),
    staffRefunds: (_) => const StaffRefundsScreen(),

    productManagement: (_) => const ProductManagementScreen(),
    productList: (_) => const pm.ProductListScreen(),
    productAdd: (_) => const AddProductScreen(),
    productPerformance: (_) => const ProductPerformanceScreen(),
    // NOTE: productDetails, productEdit, productVariants, productPricing
    // take a productId argument and are handled exclusively in
    // onGenerateRoute below (see the earlier note on route shadowing).

    // NOTE: inventoryBranch, inventoryProductDetails, inventoryFefo,
    // inventoryBatchDetails, and inventoryAdjustment are intentionally NOT
    // registered here — they take (optional or required) arguments and are
    // handled exclusively in onGenerateRoute below. A static `routes` map
    // entry always wins over onGenerateRoute for the same name, so
    // registering them in both places would silently swallow their
    // arguments.

    ownerUserManagement: (_) => const UserManagementScreen(),

    ownerDashboard: (_) => const OwnerDashboardScreen(),
    ownerBusinessOverview: (_) => const BusinessOverviewScreen(),
    ownerSalesOverview: (_) => const SalesOverviewScreen(),
    ownerSalesAnalytics: (_) => const SalesAnalyticsScreen(),
    ownerSalesTrends: (_) => const SalesTrendsScreen(),
    ownerBranchComparison: (_) => const BranchComparisonScreen(),
    ownerProductPerformance: (_) => const OwnerProductPerformanceScreen(),
    // NOTE: ownerBranchPerformance takes a branch-name argument and is
    // handled exclusively in onGenerateRoute below.
  };

  static Route<dynamic>? _rawOnGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case customerProductDetails:
        final product = settings.arguments as Product;
        return MaterialPageRoute(
          builder: (_) => ProductDetailsScreen(product: product),
        );
      case customerOrderTracking:
        final order = settings.arguments as Order;
        return MaterialPageRoute(
          builder: (_) => OrderTrackingScreen(order: order),
        );
      case customerOrderConfirmation:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => OrderConfirmationScreen(
            order: args['order'] as Order,
            itemCount: args['itemCount'] as int? ?? 1,
            total: args['total'] as double? ?? 0.0,
          ),
        );
      case customerProductList:
        final categoryId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ProductListScreen(categoryId: categoryId),
        );
      case customerOrderDetails:
        final order = settings.arguments as Order;
        return MaterialPageRoute(
          builder: (_) => OrderDetailsScreen(order: order),
        );
      case customerRepeatOrder:
        final order = settings.arguments as Order;
        return MaterialPageRoute(
          builder: (_) => RepeatOrderScreen(order: order),
        );
      case customerLoyaltyTransaction:
      // Assume arguments is LoyaltyPointTransaction if needed
        return MaterialPageRoute(
          builder: (_) => const LoyaltyTransactionScreen(),
        );
      case customerRedemptionSuccess:
        return MaterialPageRoute(
          builder: (_) => const RedemptionSuccessScreen(),
        );
      case paymentPay:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => PaymentScreen(
            orderId: args['orderId'] as String,
            amount: args['amount'] as double,
            initialMethod: args['method'] as PaymentMethod? ?? PaymentMethod.cash,
          ),
        );
      case paymentStatus:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => PaymentStatusScreen(
            orderId: args['orderId'] as String,
            amount: args['amount'] as double? ?? 0,
          ),
        );
      case customerRefundRequest:
        final order = settings.arguments as Order;
        return MaterialPageRoute(
          builder: (_) => RefundRequestScreen(order: order),
        );
      case refundProcessing:
        final request = settings.arguments as RefundRequest;
        return MaterialPageRoute(
          builder: (_) => RefundProcessingScreen(request: request),
        );
      case notificationDetail:
        final item = settings.arguments as NotificationItem;
        return MaterialPageRoute(
          builder: (_) => NotificationDetailScreen(item: item),
        );
      case staffPosCart:
        final cart = settings.arguments as Map<String, int>;
        return MaterialPageRoute(
          builder: (_) => PosCartScreen(initialCart: cart),
        );
      case staffPosPayment:
        final checkout = settings.arguments as PosCheckout;
        return MaterialPageRoute(
          builder: (_) => PosPaymentScreen(checkout: checkout),
        );
      case staffPosCashInput:
        final checkout = settings.arguments as PosCheckout;
        return MaterialPageRoute(
          builder: (_) => PosCashInputScreen(checkout: checkout),
        );
      case staffPosProcessing:
        final checkout = settings.arguments as PosCheckout;
        return MaterialPageRoute(
          builder: (_) => PosProcessingScreen(checkout: checkout),
        );
      case staffPosReceipt:
        final sale = settings.arguments as PosSaleResult;
        return MaterialPageRoute(
          builder: (_) => PosReceiptScreen(sale: sale),
        );
      case staffTransactionDetails:
        final order = settings.arguments as StaffOrder;
        return MaterialPageRoute(
          builder: (_) => TransactionDetailsScreen(order: order),
        );
      case inventoryReceive:
        final item = settings.arguments as InventoryItem?;
        return MaterialPageRoute(
          builder: (_) => ReceiveBatchScreen(initialItem: item),
        );
      case inventoryBranch:
        final branch = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => BranchInventoryScreen(branch: branch),
        );
      case inventoryProductDetails:
        final variantId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => InventoryProductDetailsScreen(variantId: variantId),
        );
      case inventoryFefo:
        final priority = settings.arguments as FefoPriority?;
        return MaterialPageRoute(
          builder: (_) => FefoScreen(initialFilter: priority),
        );
      case inventoryBatchDetails:
        final batch = settings.arguments as InventoryBatch;
        return MaterialPageRoute(
          builder: (_) => BatchDetailsScreen(batch: batch),
        );
      case inventoryAdjustment:
        final batch = settings.arguments as InventoryBatch;
        return MaterialPageRoute(
          builder: (_) => InventoryAdjustmentScreen(batch: batch),
        );
      case inventoryAdjustmentSuccess:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => InventoryAdjustmentSuccessScreen(
            productId: args['productId'] as String,
            batch: args['batch'] as InventoryBatch,
            adjustment: args['adjustment'] as int,
            newStock: args['newStock'] as int,
          ),
        );
      case productDetails:
        final productId = settings.arguments as String;
        final product = findProductById(productId);
        return MaterialPageRoute(
          builder: (_) => pm.ProductDetailsScreen(product: product),
        );
      case productEdit:
        final productId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => EditProductScreen(productId: productId),
        );
      case productVariants:
        final productId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ProductVariantsScreen(productId: productId),
        );
      case productPricing:
        final productId = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ProductPricingScreen(productId: productId),
        );
      case ownerBranchPerformance:
        final branch = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => BranchPerformanceScreen(branch: branch),
        );
      case routeOptimization:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => RouteOptimizationScreen(delivery: delivery),
        );
      case routeMap:
        // A Delivery, or {'delivery': Delivery, 'stopId': String} to focus a stop.
        final args = settings.arguments;
        final delivery = args is Map ? args['delivery'] as Delivery : args as Delivery;
        final stopId = args is Map ? args['stopId'] as String? : null;
        return MaterialPageRoute(
          builder: (_) => RouteMapScreen(delivery: delivery, focusStopId: stopId),
        );
      case deliveryManifest:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => DeliveryManifestScreen(delivery: delivery),
        );
      case deliveryDetails:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => DeliveryDetailsScreen(delivery: delivery),
        );
      case deliveryActive:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => ActiveDeliveryScreen(delivery: delivery),
        );
      case deliveryRoute:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => DeliveryRouteScreen(delivery: delivery),
        );
      case gpsTracking:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => GpsTrackingScreen(delivery: delivery),
        );
      case deliveryRouteDetails:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => RouteDetailsScreen(delivery: delivery),
        );
      case deliveryProgress:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => DeliveryProgressScreen(delivery: delivery),
        );
      case deliveryNextStop:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => NextStopScreen(delivery: delivery),
        );
      case deliveryConfirmation:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => DeliveryConfirmationScreen(
            delivery: args['delivery'] as Delivery,
            stop: args['stop'] as DeliveryStop,
          ),
        );
      case deliveryCompleted:
        final delivery = settings.arguments as Delivery;
        return MaterialPageRoute(
          builder: (_) => CompletedDeliveryScreen(delivery: delivery),
        );
      case deliveryDelayed:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => DelayedDeliveryScreen(
            delivery: args['delivery'] as Delivery,
            stop: args['stop'] as DeliveryStop,
          ),
        );
      case deliveryCancelled:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => CancelledDeliveryScreen(
            delivery: args['delivery'] as Delivery,
            stop: args['stop'] as DeliveryStop,
          ),
        );
      default:
        return null;
    }
  }
}

/// Who may open a route. See [AppRoutes._policy].
class _Access {
  /// `null` roles = any signed-in role.
  final Set<UserRole>? roles;
  final bool guest;
  final bool isPublic;

  /// Permissions a staff member must hold (see `StaffPermission`).
  final Set<String> permissions;

  const _Access(this.roles, {this.guest = false, this.permissions = const <String>{}})
      : isPublic = false;
  const _Access.public()
      : roles = null,
        guest = true,
        isPublic = true,
        permissions = const <String>{};
}
