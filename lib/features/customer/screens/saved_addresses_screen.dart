import 'package:flutter/material.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/location_picker.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/customer_profile.dart';
import '../../../data/repositories/customer_profile_repository.dart';

/// Manages the customer's real saved addresses (`customer_addresses` in
/// Supabase), each with a map pin placed on [LocationPickerScreen]. The pin is
/// what the rider and the branch see (it is copied onto every delivery order
/// at checkout); an address without one is flagged and cannot be used for a
/// delivery until it is pinned.
class SavedAddressesScreen extends StatefulWidget {
  const SavedAddressesScreen({super.key});

  @override
  State<SavedAddressesScreen> createState() => _SavedAddressesScreenState();
}

class _SavedAddressesScreenState extends State<SavedAddressesScreen> {
  List<CustomerAddress> _addresses = [];
  bool _loading = true;
  String? _error;

  String? get _uid => AuthService.instance.currentFirebaseUser?.uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid == null) {
      setState(() {
        _loading = false;
        _error = 'Please sign in again to manage your addresses.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final addresses = await AppErrors.guard(
        () => CustomerProfileRepository.instance.fetchAddresses(uid),
        scope: ErrorScope.address,
      );
      CustomerDataStore.instance.setAddresses(addresses);
      if (!mounted) return;
      setState(() {
        _addresses = addresses;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppErrors.from(e, scope: ErrorScope.address).message;
      });
    }
  }

  Future<void> _openForm({CustomerAddress? existing}) async {
    final uid = _uid;
    if (uid == null) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddressFormSheet(firebaseUid: uid, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(CustomerAddress address) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete address?'),
        content: Text('Remove "${address.label}" from your saved addresses?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await AppErrors.guard(
        () => CustomerProfileRepository.instance.deleteAddress(address.id),
        scope: ErrorScope.address,
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      final error = AppErrors.from(e, scope: ErrorScope.address);
      AppErrors.showSnack(context, error, scope: ErrorScope.address);
      // Already deleted elsewhere: the list is stale, so refresh it.
      if (error.kind == AppErrorKind.notFound) _load();
    }
  }

  /// "Pin on map" straight from an address card.
  Future<void> _pin(CustomerAddress address) async {
    final uid = _uid;
    if (uid == null) return;
    final branch = BranchController.instance.selectedBranch;
    final picked = await LocationPickerScreen.open(
      context,
      initialLatitude: address.latitude,
      initialLongitude: address.longitude,
      fallbackLatitude: branch?.latitude,
      fallbackLongitude: branch?.longitude,
    );
    if (picked == null || !mounted) return;
    try {
      await AppErrors.guard(
        () => CustomerProfileRepository.instance.updateAddressPin(
          id: address.id,
          firebaseUid: uid,
          latitude: picked.latitude,
          longitude: picked.longitude,
        ),
        scope: ErrorScope.address,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${address.label}" is pinned on the map.')));
      _load();
    } catch (e) {
      if (!mounted) return;
      AppErrors.showSnack(context, e, scope: ErrorScope.address);
    }
  }

  Future<void> _setDefault(CustomerAddress address) async {
    final uid = _uid;
    if (uid == null || address.isDefault) return;
    try {
      await AppErrors.guard(
        () => CustomerProfileRepository.instance.setDefaultAddress(uid, address.id),
        scope: ErrorScope.address,
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      AppErrors.showSnack(context, e, scope: ErrorScope.address);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Saved Addresses', showBack: true),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: AppTextStyles.bodySm, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Try again'),
                        ),
                      ],
                    ),
                  ))
                : _addresses.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_off_outlined, size: 40, color: AppColors.textMuted),
                              const SizedBox(height: 10),
                              Text('No saved addresses yet.', style: AppTextStyles.bodyMd),
                              const SizedBox(height: 4),
                              Text(
                                'Add one so checkout can fill it in automatically.',
                                style: AppTextStyles.bodySm,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          children: [
                            for (final address in _addresses) ...[
                              _AddressCard(
                                address: address,
                                onPin: () => _pin(address),
                                onEdit: () => _openForm(existing: address),
                                onDelete: () => _delete(address),
                                onSetDefault: () => _setDefault(address),
                              ),
                              const SizedBox(height: 10),
                            ],
                          ],
                        ),
                      ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Address'),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  final CustomerAddress address;
  final VoidCallback onPin;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetDefault;

  const _AddressCard({
    required this.address,
    required this.onPin,
    required this.onEdit,
    required this.onDelete,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: address.isDefault ? AppColors.primary : AppColors.border,
            width: address.isDefault ? 1.6 : 1),
        boxShadow: AppShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(address.label, style: AppTextStyles.titleMd),
                    if (address.isDefault) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.successBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Default', style: AppTextStyles.labelSm.copyWith(color: AppColors.success)),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit();
                    case 'default':
                      onSetDefault();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (!address.isDefault) const PopupMenuItem(value: 'default', child: Text('Set as default')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(address.recipientName, style: AppTextStyles.bodyMd),
          Text(address.phone, style: AppTextStyles.bodySm),
          const SizedBox(height: 4),
          Text(address.fullAddress, style: AppTextStyles.bodySm),
          const SizedBox(height: 10),
          if (address.isPinned)
            DeliveryMap(
              pin: DeliveryMap.point(address.latitude, address.longitude),
              pinLabel: address.label,
              height: 120,
              showControls: false,
              showLegend: false,
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppSpacing.radiusSm)),
              child: Row(
                children: [
                  const Icon(Icons.wrong_location_outlined, size: 18, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text('No map pin — needed for delivery orders', style: AppTextStyles.bodySm)),
                  TextButton(onPressed: onPin, child: const Text('Pin on map')),
                ],
              ),
            ),
          if (address.isPinned)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onPin,
                icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                label: const Text('Move pin'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddressFormSheet extends StatefulWidget {
  final String firebaseUid;
  final CustomerAddress? existing;

  const _AddressFormSheet({required this.firebaseUid, this.existing});

  @override
  State<_AddressFormSheet> createState() => _AddressFormSheetState();
}

class _AddressFormSheetState extends State<_AddressFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _labelController = TextEditingController(text: widget.existing?.label ?? 'Home');
  late final _recipientController = TextEditingController(text: widget.existing?.recipientName ?? '');
  late final _phoneController = TextEditingController(text: widget.existing?.phone ?? '');
  late final _line1Controller = TextEditingController(text: widget.existing?.line1 ?? '');
  late final _cityController = TextEditingController(text: widget.existing?.city ?? '');
  late final _provinceController =
      TextEditingController(text: widget.existing?.province ?? '');
  late final _postalController = TextEditingController(text: widget.existing?.postalCode ?? '');
  late bool _isDefault = widget.existing?.isDefault ?? false;
  bool _saving = false;
  late double? _lat = widget.existing?.latitude;
  late double? _lng = widget.existing?.longitude;

  /// Opens the full-screen map picker. The address fields are prefilled from
  /// the pin only where they are still empty (the customer's own typing wins);
  /// if the lookup fails the pin is still saved.
  Future<void> _pinOnMap() async {
    final branch = BranchController.instance.selectedBranch;
    final picked = await LocationPickerScreen.open(
      context,
      initialLatitude: _lat,
      initialLongitude: _lng,
      fallbackLatitude: branch?.latitude,
      fallbackLongitude: branch?.longitude,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lat = picked.latitude;
      _lng = picked.longitude;
      final a = picked.address;
      if (a != null) {
        void fill(TextEditingController c, String? v) {
          if (c.text.trim().isEmpty && (v ?? '').trim().isNotEmpty) c.text = v!.trim();
        }

        fill(_line1Controller, a.line1);
        fill(_cityController, a.city);
        fill(_provinceController, a.province);
        fill(_postalController, a.postalCode);
      }
    });
  }

  bool get _pinned => DeliveryMap.point(_lat, _lng) != null;

  @override
  void dispose() {
    _labelController.dispose();
    _recipientController.dispose();
    _phoneController.dispose();
    _line1Controller.dispose();
    _cityController.dispose();
    _provinceController.dispose();
    _postalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_pinned) {
      // Clearly warned: an address without a pin cannot be used for delivery.
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save without a map pin?'),
          content: const Text('Riders find you by the pin. You will need to pin this address before using it for a delivery order.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save anyway')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'pin'), child: const Text('Pin on map')),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'pin') {
        await _pinOnMap();
        if (!mounted || !_pinned) return;
      }
    }
    setState(() => _saving = true);
    try {
      final repo = CustomerProfileRepository.instance;
      await AppErrors.guard(() async {
        if (widget.existing == null) {
          await repo.addAddress(
            firebaseUid: widget.firebaseUid,
            label: _labelController.text.trim(),
            recipientName: _recipientController.text.trim(),
            phone: _phoneController.text.trim(),
            line1: _line1Controller.text.trim(),
            city: _cityController.text.trim(),
            province: _provinceController.text.trim(),
            postalCode: _postalController.text.trim(),
            isDefault: _isDefault,
            latitude: _lat,
            longitude: _lng,
          );
        } else {
          await repo.updateAddress(
            id: widget.existing!.id,
            firebaseUid: widget.firebaseUid,
            label: _labelController.text.trim(),
            recipientName: _recipientController.text.trim(),
            phone: _phoneController.text.trim(),
            line1: _line1Controller.text.trim(),
            city: _cityController.text.trim(),
            province: _provinceController.text.trim(),
            postalCode: _postalController.text.trim(),
            isDefault: _isDefault,
            latitude: _lat,
            longitude: _lng,
          );
        }
      }, scope: ErrorScope.address);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppErrors.showSnack(context, e, scope: ErrorScope.address);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.existing == null ? 'Add Address' : 'Edit Address',
                    style: AppTextStyles.headlineSm,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    label: 'Label',
                    controller: _labelController,
                    hint: 'Home, Work, etc.',
                    validator: (v) => ValidationUtils.validateRequired(v, 'Label'),
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    label: 'Recipient Name',
                    controller: _recipientController,
                    validator: (v) => ValidationUtils.validateName(v, 'Recipient name'),
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    label: 'Phone Number',
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    hint: '09XXXXXXXXX',
                    validator: ValidationUtils.validatePhone,
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    label: 'Address Line',
                    controller: _line1Controller,
                    hint: 'House/unit no., street, barangay',
                    validator: (v) => ValidationUtils.validateAddress(v, 'Address line'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: AppTextField(
                          label: 'City',
                          controller: _cityController,
                          validator: (v) => ValidationUtils.validateRequired(v, 'City'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppTextField(
                          label: 'Province',
                          controller: _provinceController,
                          validator: (v) => ValidationUtils.validateRequired(v, 'Province'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AppTextField(
                    label: 'Postal Code',
                    controller: _postalController,
                    keyboardType: TextInputType.number,
                    validator: (v) => ValidationUtils.validateRequired(v, 'Postal code'),
                  ),
                  const SizedBox(height: 12),
                  Text('Map pin (the rider goes exactly here)', style: AppTextStyles.labelLg),
                  const SizedBox(height: 6),
                  if (_pinned) ...[
                    DeliveryMap(
                      pin: DeliveryMap.point(_lat, _lng),
                      pinLabel: 'This address',
                      height: 150,
                      showLegend: false,
                    ),
                    const SizedBox(height: 6),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('Not pinned yet. Delivery orders need a pin.',
                          style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pinOnMap,
                          icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                          label: Text(_pinned ? 'Move pin on map' : 'Pin on map'),
                        ),
                      ),
                      if (_pinned)
                        TextButton(
                          onPressed: () => setState(() {
                            _lat = null;
                            _lng = null;
                          }),
                          child: const Text('Remove pin'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Set as default address'),
                    value: _isDefault,
                    activeThumbColor: AppColors.primary,
                    onChanged: (v) => setState(() => _isDefault = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  PrimaryButton(
                    label: 'Save Address',
                    icon: Icons.check_rounded,
                    loading: _saving,
                    onPressed: _saving ? null : _save,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
