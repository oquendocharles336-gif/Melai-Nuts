import 'package:flutter/material.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/catalog_store.dart';
import '../../../data/models/app_user.dart';
import '../../../data/models/user_role.dart';
import '../../../data/repositories/branch_repository.dart';

Future<void> _openAddUserSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _AddUserSheet(),
  );
}

/// Owner-only screen to manage staff, owner, and delivery accounts.
/// Standalone page (kept so the `/owner/users` route still works); the
/// content lives in [UserManagementBody], which is also the "Users" tab in
/// the Owner Portal.
class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Manage User Accounts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_rounded),
            onPressed: () => _openAddUserSheet(context),
          ),
        ],
      ),
      body: const UserManagementBody(),
    );
  }
}

/// User list + search. Has no Scaffold of its own so it can be used as a tab
/// body. When [showAddButton] is true (tab mode, where there is no app-bar
/// action) an "add user" button is shown next to the search field.
class UserManagementBody extends StatefulWidget {
  final bool showAddButton;
  const UserManagementBody({super.key, this.showAddButton = false});

  @override
  State<UserManagementBody> createState() => _UserManagementBodyState();
}

class _UserManagementBodyState extends State<UserManagementBody> {
  String _searchQuery = '';

  Future<void> _toggleActive(AppUser user) async {
    try {
      await AuthService.instance.setAccountActive(user.uid, !user.isActive);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            user.isActive
                ? '${user.name} deactivated — they can no longer sign in.'
                : '${user.name} reactivated.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update this account. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: const InputDecoration(
                    hintText: 'Search users by name or role...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              if (widget.showAddButton) ...[
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Add user',
                  icon: const Icon(Icons.person_add_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.roleOwner,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => _openAddUserSheet(context),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<AppUser>>(
            stream: AuthService.instance.watchManagedAccounts(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      'Could not load users. Check your connection and try again.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyMd,
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final query = _searchQuery.toLowerCase();
              final users = snapshot.data!
                  .where((u) =>
              u.name.toLowerCase().contains(query) ||
                  u.role.label.toLowerCase().contains(query) ||
                  u.email.toLowerCase().contains(query))
                  .toList()
                ..sort((a, b) => a.name.compareTo(b.name));

              if (users.isEmpty) {
                return Center(
                  child: Text(
                    _searchQuery.isEmpty
                        ? 'No staff, owner, or delivery accounts yet.\nTap + to add one.'
                        : 'No users match "$_searchQuery".',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMd,
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: users.length,
                separatorBuilder: (context, index) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final user = users[i];
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.sm,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: user.role.color.withValues(alpha: 0.15),
                          child: Icon(user.role.icon, color: user.role.color, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(user.name, style: AppTextStyles.labelLg),
                              Text(
                                user.branch != null
                                    ? '${user.role.label} • ${user.branch}'
                                    : user.role.label,
                                style: AppTextStyles.bodySm,
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              user.isActive ? 'Active' : 'Deactivated',
                              style: TextStyle(
                                color: user.isActive ? AppColors.success : AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(user.email, style: AppTextStyles.bodySm),
                          ],
                        ),
                        const SizedBox(width: 4),
                        PopupMenuButton<void>(
                          icon: const Icon(Icons.more_vert_rounded, size: 18),
                          onSelected: (_) => _toggleActive(user),
                          itemBuilder: (context) => [
                            PopupMenuItem<void>(
                              child: Text(user.isActive ? 'Deactivate' : 'Reactivate'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AddUserSheet extends StatefulWidget {
  const _AddUserSheet();

  @override
  State<_AddUserSheet> createState() => _AddUserSheetState();
}

class _AddUserSheetState extends State<_AddUserSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  UserRole _role = UserRole.staff;
  String? _branch;
  bool _submitting = false;

  bool get _needsBranch => _role == UserRole.staff || _role == UserRole.delivery;

  @override
  void initState() {
    super.initState();
    // Branch choices come from the database (`branches`), never a fixed list.
    if (kBranches.isEmpty) BranchRepository.instance.loadBranches();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final user = await AuthService.instance.createManagedAccount(
        name: _nameController.text,
        email: _emailController.text,
        password: _passwordController.text,
        role: _role,
        phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text,
        branch: _needsBranch ? _branch : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${user.name} added as ${user.role.label}.')),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Add User Account', style: AppTextStyles.headlineMd),
                const SizedBox(height: 4),
                Text(
                  'Creates a real sign-in for staff, owner, or delivery personnel.',
                  style: AppTextStyles.bodyMd,
                ),
                const SizedBox(height: 18),
                Text('Role', style: AppTextStyles.labelLg),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [UserRole.staff, UserRole.owner, UserRole.delivery]
                      .map(
                        (r) => ChoiceChip(
                      label: Text(r.label),
                      selected: _role == r,
                      onSelected: (_) => setState(() => _role = r),
                    ),
                  )
                      .toList(),
                ),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'Full Name',
                  controller: _nameController,
                  prefixIcon: Icons.person_outline_rounded,
                  validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
                ),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'Email Address',
                  controller: _emailController,
                  prefixIcon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                  validator: ValidationUtils.validateEmail,
                ),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'Mobile Number (optional)',
                  controller: _phoneController,
                  prefixIcon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? null
                      : ValidationUtils.validatePhone(v),
                ),
                const SizedBox(height: 14),
                AppTextField(
                  label: 'Temporary Password',
                  controller: _passwordController,
                  prefixIcon: Icons.lock_outline_rounded,
                  obscure: true,
                  helperText: 'Share this with them — they can change it after signing in.',
                  validator: ValidationUtils.validatePassword,
                ),
                if (_needsBranch) ...[
                  const SizedBox(height: 14),
                  Text('Branch', style: AppTextStyles.labelLg),
                  const SizedBox(height: 6),
                  ListenableBuilder(
                    listenable: BranchRepository.instance,
                    builder: (context, _) {
                      final repo = BranchRepository.instance;
                      if (kBranches.isEmpty) {
                        if (repo.isLoading) return const LinearProgressIndicator();
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                repo.error != null ? 'Could not load branches: ${repo.error!.message}' : 'No branches found.',
                                style: AppTextStyles.bodySm.copyWith(color: AppColors.error),
                              ),
                            ),
                            TextButton(onPressed: repo.loadBranches, child: const Text('Retry')),
                          ],
                        );
                      }
                      return DropdownButtonFormField<String>(
                        initialValue: kBranches.any((b) => b.name == _branch) ? _branch : null,
                        hint: const Text('Select branch'),
                        items: kBranches
                            .map((b) => DropdownMenuItem(value: b.name, child: Text(b.name)))
                            .toList(),
                        onChanged: (v) => setState(() => _branch = v),
                        validator: (v) => v == null ? 'Please select a branch.' : null,
                      );
                    },
                  ),
                ],
                const SizedBox(height: 20),
                PrimaryButton(
                  label: 'Create Account',
                  icon: Icons.person_add_alt_1_rounded,
                  loading: _submitting,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}