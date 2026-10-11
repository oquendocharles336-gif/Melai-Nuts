import 'package:flutter/material.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/owner_sales.dart';
import '../../../data/repositories/staff_repository.dart';

/// Loads the owner's server-computed sales summary (`owner_sales_summary`)
/// for the last [days] days and hands it to [builder].
///
/// It owns the loading, error + retry and pull-to-refresh behaviour so every
/// owner analytics screen handles a slow, failed or empty request the same
/// way and never shows placeholder numbers. [builder] must return a scrollable
/// (a `ListView` with `AlwaysScrollableScrollPhysics`) so pull-to-refresh works.
/// Changing [days] discards the old summary and loads the new period.
class OwnerSalesScope extends StatefulWidget {
  final int days;
  final Widget Function(BuildContext context, OwnerSalesSummary summary) builder;

  const OwnerSalesScope({super.key, required this.days, required this.builder});

  @override
  State<OwnerSalesScope> createState() => _OwnerSalesScopeState();
}

class _OwnerSalesScopeState extends State<OwnerSalesScope> {
  bool _loading = true;
  Object? _error;
  OwnerSalesSummary? _summary;

  /// Only the latest request may update the screen.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OwnerSalesScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.days != widget.days) {
      _summary = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await StaffRepository.instance.getOwnerSalesSummary(days: widget.days);
      if (!mounted || id != _requestId) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: DataStateView(
        isLoading: _loading,
        error: _error,
        isEmpty: _summary == null,
        onRetry: _load,
        emptyIcon: Icons.analytics_outlined,
        emptyTitle: 'No sales data available.',
        emptyMessage: 'Pull down to try again.',
        builder: (context) => widget.builder(context, _summary!),
      ),
    );
  }
}
