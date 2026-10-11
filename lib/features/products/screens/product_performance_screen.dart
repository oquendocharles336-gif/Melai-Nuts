import 'package:flutter/material.dart';
import '../../owner/screens/product_performance_screen.dart';

/// Product Management's entry to product performance. It shows the same
/// server-computed ranking as the owner portal, so the two can never disagree.
class ProductPerformanceScreen extends StatelessWidget {
  const ProductPerformanceScreen({super.key});

  @override
  Widget build(BuildContext context) => const OwnerProductPerformanceScreen();
}
