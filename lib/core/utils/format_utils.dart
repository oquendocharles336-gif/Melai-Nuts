import 'package:intl/intl.dart';

/// Peso amount with thousands separators, e.g. ₱1,250.00.
String peso(num value) => '₱${NumberFormat('#,##0.00').format(value)}';

/// Whole-peso amount for compact tiles, e.g. ₱1,250.
String pesoWhole(num value) => '₱${NumberFormat('#,##0').format(value)}';

/// [peso], or "—" when the server did not send the figure (never 0 for unknown).
String pesoOrDash(num? value) => value == null ? '—' : peso(value);

/// [pesoWhole], or "—" when the figure is unknown.
String pesoWholeOrDash(num? value) => value == null ? '—' : pesoWhole(value);

/// A rate from the server (0.0532) as "5.3%", or "—" when there is none
/// (e.g. a refund rate with no sales).
String rateOrDash(double? rate) => rate == null ? '—' : '${(rate * 100).toStringAsFixed(1)}%';

/// "2:05 PM" for today, "Sep 28 • 2:05 PM" for other days (device local time).
String friendlyTime(DateTime t) {
  final now = DateTime.now();
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  final time = DateFormat('h:mm a').format(t);
  return sameDay ? time : '${DateFormat('MMM d').format(t)} • $time';
}

bool isToday(DateTime t) {
  final now = DateTime.now();
  return t.year == now.year && t.month == now.month && t.day == now.day;
}
