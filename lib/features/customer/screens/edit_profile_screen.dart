import 'package:flutter/material.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../core/services/pending_writes_service.dart';
import '../../../data/models/customer_profile.dart';

/// Edits the customer's real profile (`customer_profiles` in Supabase).
/// Email isn't editable here — it's the Firebase Auth login identity, so
/// changing it belongs in Login & Security, not a plain text field that
/// would silently drift from the account.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: CustomerDataStore.instance.profile?.fullName ??
        AuthService.instance.currentProfile?.name ??
        '',
  );
  late final _phoneController =
      TextEditingController(text: CustomerDataStore.instance.profile?.phone ?? '');
  final String _email = AuthService.instance.currentFirebaseUser?.email ??
      CustomerDataStore.instance.profile?.email ??
      '';
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final firebaseUid = AuthService.instance.currentFirebaseUser?.uid;
    if (firebaseUid == null) return;

    setState(() => _saving = true);
    try {
      final name = _nameController.text.trim();
      final phone = _phoneController.text.trim();
      final outcome = await PendingWritesService.instance.run(
        firebaseUid,
        PendingWriteKind.profileUpdate,
        {'fullName': name, 'phone': phone},
      );
      if (!mounted) return;
      final store = CustomerDataStore.instance;
      switch (outcome.kind) {
        case WriteOutcomeKind.synced:
          final updated = outcome.result;
          if (updated is CustomerProfile) store.updateCachedProfile(updated);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated.')),
          );
          Navigator.of(context).pop();
        case WriteOutcomeKind.queued:
          final current = store.profile;
          if (current != null) {
            store.updateCachedProfile(current.copyWith(fullName: name, phone: phone));
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved on this device only — not on your account yet. It will sync automatically when the server is reachable.'),
              duration: Duration(seconds: 5),
            ),
          );
          Navigator.of(context).pop();
        case WriteOutcomeKind.rejected:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save profile: ${outcome.message ?? 'the server refused it'}')),
          );
      }
    } catch (e) {
      if (!mounted) return;
      AppErrors.showSnack(context, e, scope: ErrorScope.profile);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    color: AppColors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _nameController.text.isNotEmpty ? _nameController.text[0].toUpperCase() : 'U',
                      style: AppTextStyles.headlineLg.copyWith(color: AppColors.primary),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                label: 'Full Name',
                controller: _nameController,
                prefixIcon: Icons.person_outline_rounded,
                validator: (v) => ValidationUtils.validateName(v, 'Full Name'),
              ),
              const SizedBox(height: 14),
              Text('EMAIL ADDRESS', style: AppTextStyles.labelSm),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.email_outlined, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_email.isEmpty ? 'Not set' : _email, style: AppTextStyles.bodyLg)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Managed in Login & Security.', style: AppTextStyles.bodySm),
              ),
              const SizedBox(height: 14),
              AppTextField(
                label: 'Mobile Number',
                controller: _phoneController,
                prefixIcon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                helperText: 'Used for SMS alerts and delivery updates.',
                validator: ValidationUtils.validatePhone,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Save Profile Changes',
                icon: Icons.check_rounded,
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
