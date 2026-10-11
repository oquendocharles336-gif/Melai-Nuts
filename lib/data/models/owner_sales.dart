/// Server-computed sales figures for the owner screens
/// (`owner_sales_summary`). Nothing here is calculated on the device.
///
/// Definitions (database, migration 20261015000000_refunds_in_analytics.sql,
/// the same as the admin website):
///  * gross sales = orders with a successful payment, by order date (Asia/Manila)
///  * refunds     = completed refunds (partial ones included), on the day they completed
///  * net sales   = gross − discounts − refunds (the headline everywhere)
///  * refund rate = refunds ÷ (gross − discounts); null when that is 0
///  * pending refunds (requested / approved / processing) are shown apart and
///    are NOT deducted.
///
/// New fields are nullable: an older server that does not send them gives
/// `null`, which the screens show as "—" (never as 0).
library;

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;
int _i(dynamic v) => (v as num?)?.toInt() ?? 0;
double? _dn(dynamic v) => (v as num?)?.toDouble();
int? _in(dynamic v) => (v as num?)?.toInt();

/// One set of sales figures as the database returns it (`_sales_money_json`).
class SalesFigures {
  final int orders;
  final double grossSales;
  final double discounts;
  final double refunds;
  final int refundCount;
  final double netSales;
  final double deliveryFees;

  /// refunds ÷ (gross − discounts); null when there were no sales.
  final double? refundRate;

  /// null when there were no paid orders.
  final double? averageOrderValue;

  const SalesFigures({
    required this.orders,
    required this.grossSales,
    required this.discounts,
    required this.refunds,
    required this.refundCount,
    required this.netSales,
    required this.deliveryFees,
    required this.refundRate,
    required this.averageOrderValue,
  });

  /// null when [j] is not a map with the figures (older server).
  static SalesFigures? fromJson(dynamic j) {
    if (j is! Map || !j.containsKey('net_sales')) return null;
    return SalesFigures(
      orders: _i(j['orders']),
      grossSales: _d(j['gross_sales']),
      discounts: _d(j['discounts']),
      refunds: _d(j['refunds']),
      refundCount: _i(j['refund_count']),
      netSales: _d(j['net_sales']),
      deliveryFees: _d(j['delivery_fees']),
      refundRate: _dn(j['refund_rate']),
      averageOrderValue: _dn(j['average_order_value']),
    );
  }
}

/// Refunds that are requested / approved / processing right now (not deducted).
class PendingRefunds {
  final int count;
  final double amount;

  const PendingRefunds({required this.count, required this.amount});

  static PendingRefunds? fromJson(dynamic j) =>
      j is Map ? PendingRefunds(count: _i(j['count']), amount: _d(j['amount'])) : null;
}

/// One branch's sales: today, the last 7 days, and the requested window.
class OwnerBranchSales {
  final String branchId;
  final String name;

  /// Net sales (gross − discounts − refunds) per period.
  final double todayRevenue;
  final double weekRevenue;
  final double windowRevenue;

  /// Orders with a successful payment per period.
  final int ordersToday;
  final int ordersWeek;
  final int ordersWindow;

  /// Full figures per period (null on an older server).
  final SalesFigures? today;
  final SalesFigures? week;
  final SalesFigures? window;

  /// Open refunds of this branch right now (null on an older server).
  final int? pendingRefundCount;
  final double? pendingRefundAmount;

  const OwnerBranchSales({
    required this.branchId,
    required this.name,
    required this.todayRevenue,
    required this.weekRevenue,
    required this.windowRevenue,
    required this.ordersToday,
    required this.ordersWeek,
    required this.ordersWindow,
    this.today,
    this.week,
    this.window,
    this.pendingRefundCount,
    this.pendingRefundAmount,
  });

  factory OwnerBranchSales.fromJson(Map<String, dynamic> j) => OwnerBranchSales(
    branchId: (j['branch_id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    todayRevenue: _d(j['today_revenue']),
    weekRevenue: _d(j['week_revenue']),
    windowRevenue: _d(j['window_revenue']),
    ordersToday: _i(j['orders_today']),
    ordersWeek: _i(j['orders_week']),
    ordersWindow: _i(j['orders_window']),
    today: SalesFigures.fromJson(j['today']),
    week: SalesFigures.fromJson(j['week']),
    window: SalesFigures.fromJson(j['window']),
    pendingRefundCount: _in(j['pending_refund_count']),
    pendingRefundAmount: _dn(j['pending_refund_amount']),
  );
}

/// Sales of one product over the window: units sold minus units refunded and
/// net item sales (item value − its share of discounts − its refunds).
/// Grouped by the product name on the order.
class OwnerProductSales {
  final String productName;

  /// Net units (sold − refunded).
  final int units;

  /// Net item sales.
  final double revenue;

  /// null on an older server.
  final int? grossUnits;
  final int? refundedUnits;
  final double? refunds;

  const OwnerProductSales({
    required this.productName,
    required this.units,
    required this.revenue,
    this.grossUnits,
    this.refundedUnits,
    this.refunds,
  });

  factory OwnerProductSales.fromJson(Map<String, dynamic> j) => OwnerProductSales(
    productName: (j['product_name'] as String?) ?? '',
    units: _i(j['units']),
    revenue: _d(j['revenue']),
    grossUnits: _in(j['gross_units']),
    refundedUnits: _in(j['refunded_units']),
    refunds: _dn(j['refunds']),
  );
}

/// Net sales for one calendar day (Asia/Manila). A refund counts on the day it
/// completed, so a day can show refunds of earlier sales.
class OwnerDailySales {
  final DateTime date;

  /// Net sales of the day.
  final double revenue;

  /// Gross / discounts / refunds of the day (null on an older server).
  final SalesFigures? figures;

  const OwnerDailySales({required this.date, required this.revenue, this.figures});

  factory OwnerDailySales.fromJson(Map<String, dynamic> j) => OwnerDailySales(
    date: DateTime.parse(j['date'] as String),
    revenue: _d(j['revenue']),
    figures: SalesFigures.fromJson(j),
  );
}

class OwnerSalesSummary {
  final int days;
  final List<OwnerBranchSales> branches;
  final List<OwnerProductSales> products;
  final List<OwnerDailySales> daily;

  /// All branches together, per period, computed by the database
  /// (null on an older server: screens show "—").
  final SalesFigures? totalToday;
  final SalesFigures? totalWeek;
  final SalesFigures? totalWindow;
  final PendingRefunds? pendingRefunds;

  const OwnerSalesSummary({
    required this.days,
    required this.branches,
    required this.products,
    required this.daily,
    this.totalToday,
    this.totalWeek,
    this.totalWindow,
    this.pendingRefunds,
  });

  factory OwnerSalesSummary.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> rows(dynamic v) => [
      for (final e in (v as List? ?? const [])) Map<String, dynamic>.from(e as Map),
    ];
    final totals = j['totals'] is Map ? Map<String, dynamic>.from(j['totals'] as Map) : const <String, dynamic>{};
    return OwnerSalesSummary(
      days: _i(j['days']),
      branches: rows(j['branches']).map(OwnerBranchSales.fromJson).toList(),
      products: rows(j['products']).map(OwnerProductSales.fromJson).toList(),
      daily: rows(j['daily']).map(OwnerDailySales.fromJson).toList(),
      totalToday: SalesFigures.fromJson(totals['today']),
      totalWeek: SalesFigures.fromJson(totals['week']),
      totalWindow: SalesFigures.fromJson(totals['window']),
      pendingRefunds: PendingRefunds.fromJson(totals['pending_refunds']),
    );
  }
}
