import 'package:flutter/material.dart';

import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/navigation_sheet.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/repositories/delivery_repository.dart';

/// Registered drivers per branch (`staff_list_drivers`): availability, open
/// runs, vehicle and phone. Owner: every branch; staff: their own branch.
/// Drivers are created and suspended by the owner in User Management.
class DriverDirectoryScreen extends StatelessWidget {
  const DriverDirectoryScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      StaffDataScope(builder: (context, store) => _DriverDirectoryBody(store: store));
}

class _DriverDirectoryBody extends StatefulWidget {
  final StaffStore store;
  const _DriverDirectoryBody({required this.store});

  @override
  State<_DriverDirectoryBody> createState() => _DriverDirectoryBodyState();
}

class _DriverDirectoryBodyState extends State<_DriverDirectoryBody> {
  bool _loading = true;
  Object? _error;
  List<BranchDriver> _drivers = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Owner: every branch (null); staff: the database answers their branch.
      final drivers = await DeliveryRepository.instance.listDrivers(widget.store.isOwner ? null : widget.store.activeBranchId);
      if (!mounted) return;
      setState(() {
        _drivers = drivers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String _branchName(String? id) {
    for (final b in kBranches) {
      if (b.id == id) return b.name;
    }
    return id == widget.store.activeBranchId && widget.store.activeBranchName.isNotEmpty
        ? widget.store.activeBranchName
        : 'Branch';
  }

  @override
  Widget build(BuildContext context) {
    final byBranch = <String, List<BranchDriver>>{};
    for (final d in _drivers) {
      byBranch.putIfAbsent(_branchName(d.branchId), () => []).add(d);
    }
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Drivers', showBack: true),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: DataStateView(
            isLoading: _loading,
            error: _error,
            isEmpty: _drivers.isEmpty,
            onRetry: _load,
            emptyIcon: Icons.delivery_dining_outlined,
            emptyTitle: 'No registered drivers',
            emptyMessage: 'The owner registers drivers in User Management (role: Delivery). They sign in to this app.',
            builder: (context) => ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                for (final entry in byBranch.entries) ...[
                  Text(entry.key, style: AppTextStyles.headlineSm),
                  const SizedBox(height: AppSpacing.xs),
                  for (final d in entry.value)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: (d.isActive && d.isAvailable ? AppColors.success : AppColors.textSecondary)
                                  .withValues(alpha: 0.15),
                              child: Icon(Icons.delivery_dining_rounded,
                                  color: d.isActive && d.isAvailable ? AppColors.success : AppColors.textSecondary),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(d.fullName, style: AppTextStyles.labelLg),
                                  Text(
                                    [
                                      !d.isActive
                                          ? (d.accountStatus == 'suspended' ? 'Suspended' : 'Inactive')
                                          : (d.isAvailable ? 'Available' : 'Off duty'),
                                      if (d.activeRuns > 0) '${d.activeRuns} open run${d.activeRuns == 1 ? '' : 's'}',
                                      if ((d.vehicle ?? '').isNotEmpty) d.vehicle!,
                                    ].join(' • '),
                                    style: AppTextStyles.bodySm,
                                  ),
                                ],
                              ),
                            ),
                            if ((d.phone ?? '').isNotEmpty)
                              IconButton(
                                tooltip: 'Call ${d.fullName}',
                                icon: const Icon(Icons.call_outlined),
                                onPressed: () => callNumber(context, d.phone),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
