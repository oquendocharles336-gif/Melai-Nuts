import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/core/utils/format_utils.dart';
import 'package:melai_nuts/data/models/loyalty.dart';
import 'package:melai_nuts/data/models/owner_sales.dart';
import 'package:melai_nuts/data/models/refund_summary.dart';
import 'package:melai_nuts/data/models/staff_models.dart';

// Parsing of the refund-aware sales figures
// (supabase/migrations/20261015000000_refunds_in_analytics.sql). The app only
// reads what the database computed; an older server's answer must give null
// ("—"), never 0 or a figure computed on the device.
void main() {
  group('SalesFigures', () {
    test('reads the database figures as they are', () {
      final f = SalesFigures.fromJson({
        'orders': 6, 'gross_sales': 1300, 'discounts': 0, 'refunds': 690, 'refund_count': 5,
        'net_sales': 610, 'delivery_fees': 0, 'revenue': 610, 'refund_rate': 0.5308, 'average_order_value': 216.67,
      })!;
      expect(f.netSales, 610);
      expect(f.grossSales, 1300);
      expect(f.refunds, 690);
      expect(f.refundCount, 5);
      expect(f.refundRate, 0.5308);
      expect(f.averageOrderValue, 216.67);
    });

    test('no figures (older server) is null, not zero', () {
      expect(SalesFigures.fromJson(null), isNull);
      expect(SalesFigures.fromJson({'date': '2026-10-10', 'revenue': 100}), isNull);
    });

    test('a period without sales has no refund rate and no average', () {
      final f = SalesFigures.fromJson({'orders': 0, 'gross_sales': 0, 'net_sales': 0, 'refund_rate': null, 'average_order_value': null})!;
      expect(f.refundRate, isNull);
      expect(f.averageOrderValue, isNull);
      expect(rateOrDash(f.refundRate), '—');
    });
  });

  group('OwnerSalesSummary', () {
    final current = <String, dynamic>{
      'days': 30,
      'branches': [
        {
          'branch_id': 'b-1', 'name': 'Calamba', 'today_revenue': 610, 'week_revenue': 880, 'window_revenue': 880,
          'orders_today': 6, 'orders_week': 7, 'orders_window': 7,
          'today': {'orders': 6, 'gross_sales': 1300, 'discounts': 0, 'refunds': 690, 'refund_count': 5, 'net_sales': 610},
          'week': {'orders': 7, 'gross_sales': 1600, 'discounts': 30, 'refunds': 690, 'refund_count': 5, 'net_sales': 880},
          'window': {'orders': 7, 'gross_sales': 1600, 'discounts': 30, 'refunds': 690, 'refund_count': 5, 'net_sales': 880},
          'pending_refund_count': 1, 'pending_refund_amount': 100,
        },
      ],
      'products': [
        {'product_name': 'Garlic Peanuts', 'units': 9, 'revenue': 880, 'gross_units': 16, 'refunded_units': 7, 'refunds': 690},
      ],
      'daily': [
        {'date': '2026-10-09', 'revenue': 270, 'orders': 1, 'gross_sales': 300, 'discounts': 30, 'refunds': 0, 'refund_count': 0, 'net_sales': 270},
        {'date': '2026-10-10', 'revenue': 610, 'orders': 6, 'gross_sales': 1300, 'discounts': 0, 'refunds': 690, 'refund_count': 5, 'net_sales': 610},
      ],
      'totals': {
        'today': {'orders': 6, 'gross_sales': 1300, 'refunds': 690, 'net_sales': 610},
        'week': {'orders': 7, 'gross_sales': 1600, 'refunds': 690, 'net_sales': 880},
        'window': {'orders': 7, 'gross_sales': 1600, 'refunds': 690, 'net_sales': 880, 'refund_rate': 0.4395},
        'pending_refunds': {'count': 1, 'amount': 100},
      },
    };

    test('net sales is the headline; gross, refunds and pending come with it', () {
      final s = OwnerSalesSummary.fromJson(current);
      final b = s.branches.single;
      expect(b.todayRevenue, 610);
      expect(b.today!.grossSales, 1300);
      expect(b.today!.refunds, 690);
      expect(b.window!.discounts, 30);
      expect(b.pendingRefundAmount, 100);
      expect(s.totalWindow!.netSales, 880);
      expect(s.totalWindow!.refundRate, 0.4395);
      expect(s.pendingRefunds!.count, 1);
      expect(s.products.single.units, 9);
      expect(s.products.single.refundedUnits, 7);
      expect(s.daily.last.figures!.refunds, 690, reason: 'a refund counts on the day it completed');
      expect(s.daily.first.figures!.refunds, 0);
    });

    test('an older server answer parses, new figures are null', () {
      final s = OwnerSalesSummary.fromJson({
        'days': 7,
        'branches': [
          {'branch_id': 'b-1', 'name': 'Calamba', 'today_revenue': 400, 'week_revenue': 900, 'window_revenue': 900,
           'orders_today': 2, 'orders_week': 4, 'orders_window': 4},
        ],
        'products': [{'product_name': 'Garlic Peanuts', 'units': 4, 'revenue': 400}],
        'daily': [{'date': '2026-10-10', 'revenue': 400}],
      });
      expect(s.totalToday, isNull);
      expect(s.pendingRefunds, isNull);
      expect(s.branches.single.today, isNull);
      expect(s.branches.single.pendingRefundAmount, isNull);
      expect(s.products.single.refundedUnits, isNull);
      expect(s.daily.single.figures, isNull);
      expect(pesoOrDash(s.totalToday?.netSales), '—');
    });
  });

  group('StaffDashboard', () {
    Map<String, dynamic> base() => {
          'branch': {'id': 'b-1', 'name': 'Calamba'},
          'sales_today': 610,
          'orders_today': 7,
          'generated_at': '2026-10-10T02:00:00Z',
        };

    test('net sales, refunds and pending refund amount', () {
      final d = StaffDashboard.fromJson(base()
        ..addAll({
          'net_sales_today': 610, 'gross_sales_today': 1300, 'discounts_today': 0, 'refunds_today': 690,
          'refund_count_today': 5, 'refund_rate_today': 0.5308, 'paid_orders_today': 6,
          'pending_refunds': 1, 'pending_refund_amount': 100,
        }));
      expect(d.netSalesToday, 610);
      expect(d.refundsToday, 690);
      expect(d.refundCountToday, 5);
      expect(d.pendingRefunds, 1);
      expect(d.pendingRefundAmount, 100);
    });

    test('older server or no refund permission: unknown, not zero', () {
      final d = StaffDashboard.fromJson(base());
      expect(d.netSalesToday, isNull);
      expect(d.refundsToday, isNull);
      expect(d.pendingRefunds, isNull);
      expect(d.pendingRefundAmount, isNull);
      expect(pesoOrDash(d.netSalesToday), '—');
    });
  });

  group('OrderRefundSummary', () {
    test('partial refund with points reversed', () {
      final r = OrderRefundSummary.fromJson({
        'state': 'partial', 'refunded_amount': 100, 'refund_count': 1, 'refunded_units': 1,
        'refunded_at': '2026-10-10T03:00:00Z', 'pending_amount': 0, 'pending_status': null,
        'points_reversed': 2, 'refundable_amount': 300,
      })!;
      expect(r.isPartial, isTrue);
      expect(r.isRefunded, isTrue);
      expect(r.hasPending, isFalse);
      expect(r.label, 'Partially refunded');
      expect(r.refundedAmount, 100);
      expect(r.pointsReversed, 2);
      expect(r.refundableAmount, 300);
      expect(r.refundedAt, isNotNull);
    });

    test('pending refund is not a refunded amount', () {
      final r = OrderRefundSummary.fromJson({'state': 'pending', 'refunded_amount': 0, 'pending_amount': 100, 'pending_status': 'pending'})!;
      expect(r.isRefunded, isFalse);
      expect(r.hasPending, isTrue);
      expect(r.label, 'Refund pending');
    });

    test('missing summary (older server) is null', () {
      expect(OrderRefundSummary.fromJson(null), isNull);
    });
  });

  group('StaffOrder / StaffRefund', () {
    test('order carries its refund summary', () {
      final o = StaffOrder.fromJson({
        'id': 'ORD-1', 'created_at': '2026-10-10T02:00:00Z', 'status': 'refunded', 'total': 400, 'items': [],
        'payment': {'id': 'PAY-1', 'method': 'cash', 'status': 'refunded', 'amount': 400},
        'refund_summary': {'state': 'partial', 'refunded_amount': 100, 'refunded_units': 1, 'points_reversed': 2},
      });
      expect(o.refund!.isPartial, isTrue);
      expect(o.refund!.refundedAmount, 100);
    });

    test('refund carries partial flag, completion and returned items', () {
      final r = StaffRefund.fromJson({
        'id': 'RFD-1', 'order_id': 'ORD-2', 'status': 'completed', 'amount': 200, 'payment_method': 'cash',
        'created_at': '2026-10-10T02:00:00Z', 'completed_at': '2026-10-10T03:00:00Z', 'order_total': 200, 'is_partial': false,
        'items': [{'product_name': 'Garlic Peanuts', 'variant_label': 'Regular', 'quantity': 2, 'unit_price': 100}],
        'returned': [
          {'product_name': 'Garlic Peanuts', 'variant_label': 'Regular', 'quantity': 1, 'condition': 'sellable'},
          {'product_name': 'Garlic Peanuts', 'variant_label': 'Regular', 'quantity': 1, 'condition': 'expired'},
        ],
      });
      expect(r.completedAt, isNotNull);
      expect(r.isPartial, isFalse);
      expect(r.returned.where((g) => g.restocked).length, 1, reason: 'only sellable units go back to stock');
    });

    test('older refund rows still parse', () {
      final r = StaffRefund.fromJson({
        'id': 'RFD-1', 'order_id': 'ORD-2', 'status': 'pending', 'amount': 100, 'created_at': '2026-10-10T02:00:00Z',
      });
      expect(r.completedAt, isNull);
      expect(r.isPartial, isNull);
      expect(r.returned, isEmpty);
    });
  });

  test('a refund reversal is not points spent', () {
    final t = LoyaltyPointTransaction.fromRow({
      'id': 'LTX-1', 'created_at': '2026-10-10T02:00:00Z', 'points': -2, 'type': 'redeem',
      'description': 'Points reversed - order ORD-1 refunded (partial)', 'source': 'order_clawback', 'order_id': 'ORD-1',
    });
    expect(t.isRefundReversal, isTrue);
    expect(t.points, 2);
  });
}
