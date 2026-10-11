/// A single labeled point in a bar/trend chart (e.g. one day or one week).
class RevenuePoint {
  final String label;
  final double value;
  final bool isProjection;

  const RevenuePoint(this.label, this.value, {this.isProjection = false});
}
