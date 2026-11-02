import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/repositories/branch_repository.dart';

/// Staff, owner and delivery accounts only. Customers never pick a branch: it
/// follows their location (see [BranchController]).
///
/// Staff and drivers work at the branch the owner assigned (shown read-only);
/// the owner picks which branch the app shows, applied for real through
/// [StaffStore.setOwnerBranch]. Branch names always come from the database.
class BranchSettingsScreen extends StatefulWidget {
  const BranchSettingsScreen({super.key});

  @override
  State<BranchSettingsScreen> createState() => _BranchSettingsScreenState();
}

class _BranchSettingsScreenState extends State<BranchSettingsScreen> {
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

  @override
  void initState() {
    super.initState();
    if (kBranches.isEmpty) BranchRepository.instance.loadBranches();
  }

  @override
  Widget build(BuildContext context) {
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
