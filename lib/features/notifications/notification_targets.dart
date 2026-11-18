import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../core/services/customer_data_store.dart';
import '../../core/services/staff_store.dart';
import '../../core/utils/app_error.dart';
import '../../data/models/order.dart';
import '../../data/models/staff_models.dart';
import '../../data/repositories/orders_repository.dart';
import '../../data/repositories/staff_repository.dart';
import '../customer/screens/order_details_screen.dart';

/// Where tapping a notification takes the user — the order / transaction or
/// list it is about. Shared by the in-app notification lists and push taps so
/// both always open the same place.
class NotificationTargets {
  NotificationTargets._();

  static final RegExp _orderId = RegExp(r'ORD-\d+');

  /// The order id a notification's text mentions (e.g. "Order ORD-1010 completed").
  static String? orderIdIn(String? title, String? body) =>
      _orderId.firstMatch('${title ?? ''} ${body ?? ''}')?.group(0);

  // ---- Customer -------------------------------------------------------------

  /// Opens the customer's order this notification is about. Returns false when
  /// the text names no order or the order could not be loaded, so the caller
  /// can show the plain notification instead.
  static Future<bool> openCustomerOrder(NavigatorState navigator, String? orderId) async {
    if (orderId == null) return false;
    Order? order;
    for (final o in CustomerDataStore.instance.orders) {
      if (o.id == orderId) order = o;
    }
    try {
      // Always prefer the latest copy so the status shown matches the update.
      order = await OrdersRepository.instance.refetch(orderId);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'notification_targets:customer_order');
      // Offline: fall back to the cached copy if there is one.
    }
    if (order == null || !navigator.mounted) return false;
    final found = order;
    navigator.push(MaterialPageRoute(builder: (_) => OrderDetailsScreen(order: found)));
    return true;
  }

  // ---- Staff ----------------------------------------------------------------

  /// Opens what a staff notification is about. Returns false when there is
  /// nothing to open (e.g. the order is no longer visible to this account).
  static Future<bool> openForStaff(
    NavigatorState navigator, {
    required String? category,
    required String? reference,
    String? title,
    String? body,
  }) async {
    final store = StaffStore.instance;
    switch (category) {
      case 'inventory':
        final isExpiry = (reference ?? '').startsWith('expiry:') ||
            (title ?? '').toLowerCase().contains('expir');
        navigator.pushNamed(isExpiry ? AppRoutes.inventoryExpiring : AppRoutes.inventoryLowStock);
        return true;
      case 'refund':
        if (!store.canReviewRefunds) return false;
        navigator.pushNamed(AppRoutes.staffRefunds);
        return true;
      case 'order':
        final id = reference ?? orderIdIn(title, body);
        if (id == null) return false;
        final order = await _staffOrder(store, id);
        if (order == null || !navigator.mounted) return false;
        navigator.pushNamed(AppRoutes.staffTransactionDetails, arguments: order);
        return true;
    }
    return false;
  }

  static Future<StaffOrder?> _staffOrder(StaffStore store, String id) async {
    for (final o in store.orders) {
      if (o.id == id) return o;
    }
    // Older than the recent list: ask for that one order.
    try {
      return await StaffRepository.instance.fetchOrder(store.activeBranchId, id);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'notification_targets:staff_order');
      return null;
    }
  }
}
