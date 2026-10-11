import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:melai_nuts/data/catalog_store.dart';
import '../../../app/routes.dart';
import '../../../core/services/audit_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/audit_entry.dart';
import '../../products/screens/product_management_screen.dart';
import '../widgets/owner_branch_tile.dart';
import '../widgets/owner_sales_scope.dart';
import 'owner_dashboard_screen.dart';
import 'owner_profile_screen.dart';
import 'user_management_screen.dart';

/// Owner Executive Dashboard — Sales analytics, multi-branch comparisons,
/// product & pricing, user management, and profile (incl. Log Out) behind a
/// single bottom-navigation shell.
class OwnerPortalScreen extends StatefulWidget {
  const OwnerPortalScreen({super.key});

  @override
  State<OwnerPortalScreen> createState() => _OwnerPortalScreenState();
}

class _OwnerPortalScreenState extends State<OwnerPortalScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.roleOwner,
              child: Icon(Icons.insights_rounded, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Owner Dashboard', style: AppTextStyles.labelLg),
                Text('Laguna Enterprise Overview', style: AppTextStyles.bodySm),
              ],
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          OwnerDashboardScreen(),
          _BranchComparisonTab(),
          _SystemLogsTab(),
          ProductManagementBody(),
          UserManagementBody(showAddButton: true),
          OwnerProfileBody(),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: AppColors.roleOwner.withValues(alpha: 0.15),
          surfaceTintColor: Colors.transparent,
          // Six tabs share the bar, so use a slightly smaller label to keep
          // "Dashboard" / "Branches" from clipping on narrow phones.
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final base = AppTextStyles.labelMd.copyWith(fontSize: 10.5, letterSpacing: 0);
            if (states.contains(WidgetState.selected)) {
              return base.copyWith(color: AppColors.roleOwner);
            }
            return base;
          }),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard_rounded, color: AppColors.roleOwner),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.compare_arrows_rounded),
              selectedIcon: Icon(Icons.compare_arrows_rounded, color: AppColors.roleOwner),
              label: 'Branches',
            ),
            NavigationDestination(
              icon: Icon(Icons.security_rounded),
              selectedIcon: Icon(Icons.security_rounded, color: AppColors.roleOwner),
              label: 'Security',
            ),
            NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined),
              selectedIcon: Icon(Icons.inventory_2_rounded, color: AppColors.roleOwner),
              label: 'Products',
              tooltip: 'Product & Pricing Hub',
            ),
            NavigationDestination(
              icon: Icon(Icons.manage_accounts_outlined),
              selectedIcon: Icon(Icons.manage_accounts_rounded, color: AppColors.roleOwner),
              label: 'Users',
              tooltip: 'Manage Users',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded, color: AppColors.roleOwner),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchComparisonTab extends StatelessWidget {
  const _BranchComparisonTab();

  @override
  Widget build(BuildContext context) {
    return OwnerSalesScope(
      days: 7,
      builder: (context, summary) {
        final branches = [...summary.branches]..sort((a, b) => b.weekRevenue.compareTo(a.weekRevenue));
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Branch Operations', style: AppTextStyles.headlineSm),
                TextButton(
                  onPressed: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchComparison),
                  child: const Text('Full Comparison'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (branches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No branches found.', style: AppTextStyles.bodyMd)),
              ),
            for (var i = 0; i < branches.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OwnerBranchTile(
                  sales: branches[i],
                  rank: i + 1,
                  onTap: () => Navigator.of(context).pushNamed(AppRoutes.ownerBranchPerformance, arguments: branches[i].name),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The real, append-only audit trail (`staff_audit_logs`). The owner's row
/// level security returns every staff member's entries.
class _SystemLogsTab extends StatefulWidget {
  const _SystemLogsTab();

  @override
  State<_SystemLogsTab> createState() => _SystemLogsTabState();
}

class _SystemLogsTabState extends State<_SystemLogsTab> {
  static final _time = DateFormat('MMM d, h:mm a');

  bool _loading = true;
  Object? _error;
  List<AuditEntry> _entries = const [];

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
      final entries = await AuditService.instance.fetchRecent(limit: 100);
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  /// `inventory.adjust` -> `Inventory adjust`.
  static String _actionLabel(String action) {
    final text = action.replaceAll('.', ' ').replaceAll('_', ' ');
    return text.isEmpty ? action : text[0].toUpperCase() + text.substring(1);
  }

  String _branchName(String? id) {
    if (id == null) return 'No branch';
    for (final b in kBranches) {
      if (b.id == id) return b.name;
    }
    return 'Unknown branch';
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: DataStateView(
        isLoading: _loading,
        error: _error,
        isEmpty: _entries.isEmpty,
        onRetry: _load,
        emptyIcon: Icons.history_toggle_off_rounded,
        emptyTitle: 'No audit entries yet.',
        emptyMessage: 'Actions such as stock adjustments and price changes appear here.',
        builder: (context) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text('Enterprise Audit Logs', style: AppTextStyles.labelSm),
            const SizedBox(height: 10),
            for (final e in _entries)
              ListTile(
                leading: const Icon(Icons.history_toggle_off_rounded, size: 20),
                title: Text(_actionLabel(e.action), style: AppTextStyles.labelLg),
                subtitle: Text(
                  '${_branchName(e.branchId)} • ${e.entityType}'
                  '${e.entityId == null ? '' : ' ${e.entityId!.length > 8 ? e.entityId!.substring(0, 8) : e.entityId}'}'
                  ' • staff ${e.staffFirebaseUid.length > 6 ? e.staffFirebaseUid.substring(0, 6) : e.staffFirebaseUid}',
                  style: AppTextStyles.bodySm,
                ),
                trailing: Text(_time.format(e.createdAt), style: AppTextStyles.bodySm),
              ),
          ],
        ),
      ),
    );
  }
}
