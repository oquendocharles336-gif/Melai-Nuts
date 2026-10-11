import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/branch.dart';
import '../../../data/models/user_role.dart';
import '../../../data/repositories/branch_repository.dart';
import '../../customer/cart_controller.dart';

/// Branch picker, reached from Settings.
///
/// For customers this is real: it loads actual branches from Supabase (name,
/// address, phone, hours, operating status, delivery/pickup availability),
/// lets them pick one, persists it to their profile via [BranchController],
/// and re-scopes the product catalog's stock/availability to that branch.
///
/// Staff, owner and delivery accounts: the branch is not a preference. Staff
/// and drivers work at the branch the owner assigned (shown read-only); the
/// owner picks which branch the app shows, applied for real through
/// [StaffStore.setOwnerBranch]. Branch names always come from the database.
class BranchSettingsScreen extends StatefulWidget {
  const BranchSettingsScreen({super.key});

  @override
  State<BranchSettingsScreen> createState() => _BranchSettingsScreenState();
}

class _BranchSettingsScreenState extends State<BranchSettingsScreen> {
  // Guests (no profile at all — customer storefront browsing allows this)
  // get the same real branch picker as signed-in customers; only the
  // persistence step is skipped for them. Staff/owner/delivery keep the
  // original simple picker below.
  bool get _isCustomer {
    final role = AuthService.instance.currentProfile?.role;
    return role == null || role == UserRole.customer;
  }

  // --- Staff / owner / delivery path ---------------------------------------
  String? _ownerPick;
  bool _applying = false;

  Future<void> _applyOwnerBranch() async {
    final id = _ownerPick;
    if (id == null) return;
    setState(() => _applying = true);
    try {
      await StaffStore.instance.setOwnerBranch(id);
      if (!mounted) return;
      final name = kBranches.where((b) => b.id == id).map((b) => b.name).firstOrNull ?? 'the branch';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Now viewing $name.')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      AppErrors.showSnack(context, e); // customer-safe wording, never the raw error
    }
  }

  // --- Customer path --------------------------------------------------------
  String? _pendingBranchId;

  @override
  void initState() {
    super.initState();
    _pendingBranchId = BranchController.instance.selectedBranch?.id;
    if (kBranches.isEmpty) BranchRepository.instance.loadBranches();
  }

  Future<void> _confirmCustomerSelection() async {
    final branchId = _pendingBranchId;
    if (branchId == null) return;
    final branch = kBranches.where((b) => b.id == branchId);
    if (branch.isEmpty) return;
    final firebaseUid = AuthService.instance.currentFirebaseUser?.uid;
    if (firebaseUid != null) {
      final cartSwitched = await CartController.instance.switchBranch(branch.first.id);
      if (!cartSwitched) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(CartController.instance.lastError ?? 'Could not switch branch while the current cart is waiting to sync.')),
        );
        return;
      }
    }
    await BranchController.instance.selectBranch(branch.first, firebaseUid: firebaseUid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Branch set to ${branch.first.name}.')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCustomer) return _buildLegacy(context);

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Select Branch', showBack: true),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: BranchRepository.instance,
          builder: (context, _) {
            final repo = BranchRepository.instance;
            return DataStateView(
              isLoading: repo.isLoading,
              error: repo.error,
              isEmpty: !kBranches.any((b) => b.servesCustomers),
              onRetry: () => repo.loadBranches(),
              emptyIcon: Icons.storefront_outlined,
              emptyTitle: 'No branches are available right now.',
              emptyMessage: 'Please check back soon.',
              loadingMessage: 'Loading branches...',
              builder: (context) => ListenableBuilder(
                listenable: BranchController.instance,
                builder: (context, _) {
                  return RefreshIndicator(
                    onRefresh: () => repo.loadBranches(),
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      children: [
                        Text('Choose your branch', style: AppTextStyles.titleMd),
                        const SizedBox(height: 4),
                        Text(
                          'Sets which branch\'s stock, pricing, and delivery options you see.',
                          style: AppTextStyles.bodySm,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        // Warehouses only hold stock: customers never pick them.
                        for (final branch in kBranches.where((b) => b.servesCustomers)) ...[
                          _BranchCard(
                            branch: branch,
                            selected: _pendingBranchId == branch.id,
                            onTap: branch.isActive
                                ? () => setState(() => _pendingBranchId = branch.id)
                                : null,
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ListenableBuilder(
            listenable: BranchController.instance,
            builder: (context, _) => PrimaryButton(
              label: 'Save Branch',
              icon: Icons.check_rounded,
              loading: BranchController.instance.isSwitching,
              onPressed: _pendingBranchId == null || BranchController.instance.isSwitching
                  ? null
                  : _confirmCustomerSelection,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLegacy(BuildContext context) {
    final store = StaffStore.instance;
    final isOwner = store.isOwner;
    final repo = BranchRepository.instance;
    _ownerPick ??= store.activeBranchId;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Branch Settings', showBack: true),
      body: SafeArea(
        child: !isOwner
            ? ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Text('Your Branch', style: AppTextStyles.titleMd),
                  const SizedBox(height: 4),
                  Text(
                    store.activeBranchName.isEmpty
                        ? 'No branch is assigned to this account yet. Ask the owner to assign one in User Management.'
                        : store.activeBranchName,
                    style: AppTextStyles.labelLg,
                  ),
                  const SizedBox(height: 8),
                  Text('Your branch is assigned by the owner and cannot be changed here.', style: AppTextStyles.bodySm),
                ],
              )
            : ListenableBuilder(
                listenable: repo,
                builder: (context, _) => DataStateView(
                  isLoading: repo.isLoading && kBranches.isEmpty,
                  error: kBranches.isEmpty ? repo.error : null,
                  onRetry: repo.loadBranches,
                  isEmpty: kBranches.isEmpty,
                  emptyIcon: Icons.storefront_outlined,
                  emptyTitle: 'No branches found.',
                  builder: (context) => ListView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
                      Text('Branch to View', style: AppTextStyles.titleMd),
                      const SizedBox(height: 4),
                      Text('Inventory and branch screens show this branch. Sales reports still cover every branch.', style: AppTextStyles.bodySm),
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppShadows.sm,
                        ),
                        child: RadioGroup<String>(
                          groupValue: _ownerPick,
                          onChanged: (v) => setState(() => _ownerPick = v ?? _ownerPick),
                          child: Column(
                            children: [
                              for (final branch in kBranches) ...[
                                RadioListTile<String>(
                                  value: branch.id,
                                  activeColor: AppColors.primary,
                                  title: Text(branch.name, style: AppTextStyles.labelLg),
                                  secondary: const Icon(Icons.storefront_outlined, color: AppColors.darkBrown),
                                ),
                                if (branch != kBranches.last) const Divider(height: 1),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: !isOwner
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: PrimaryButton(
                  label: 'View This Branch',
                  icon: Icons.check_rounded,
                  loading: _applying,
                  onPressed: _ownerPick == null || _applying ? null : _applyOwnerBranch,
                ),
              ),
            ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  final Branch branch;
  final bool selected;
  final VoidCallback? onTap;

  const _BranchCard({required this.branch, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: disabled ? AppColors.canvas : Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.6 : 1),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storefront_rounded, color: disabled ? AppColors.textMuted : AppColors.darkBrown),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    branch.name,
                    style: AppTextStyles.titleMd.copyWith(color: disabled ? AppColors.textMuted : null),
                  ),
                ),
                _StatusChip(isActive: branch.isActive),
                if (selected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_circle_rounded, color: AppColors.primary),
                ],
              ],
            ),
            if (branch.address.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(branch.address, style: AppTextStyles.bodySm),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (branch.contactPhone != null && branch.contactPhone!.isNotEmpty)
                  _InfoPill(icon: Icons.call_outlined, label: branch.contactPhone!),
                if (branch.operatingHours != null && branch.operatingHours!.isNotEmpty)
                  _InfoPill(icon: Icons.access_time_rounded, label: branch.operatingHours!),
                _InfoPill(
                  icon: Icons.delivery_dining_outlined,
                  label: branch.supportsDelivery ? 'Delivery available' : 'Pickup only',
                ),
                if (branch.supportsPickup)
                  const _InfoPill(icon: Icons.store_mall_directory_outlined, label: 'Pickup available'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool isActive;

  const _StatusChip({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isActive ? AppColors.successBg : AppColors.errorBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isActive ? 'Open' : 'Temporarily Closed',
        style: AppTextStyles.labelSm.copyWith(color: isActive ? AppColors.success : AppColors.error),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.labelSm),
        ],
      ),
    );
  }
}
