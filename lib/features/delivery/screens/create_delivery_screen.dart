import 'dart:async';

import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/catalog_store.dart';
import '../../../data/repositories/delivery_repository.dart';
import '../widgets/run_map_card.dart';

/// "Create Delivery" — pick which real, delivery-ready orders to dispatch
/// together, plus a vehicle and rider, then create the delivery for real.
///
/// There is no geocoding/routing API available to this app, so the per-stop
/// distance/time/ETA the backend computes is a simple, honestly-labeled
/// estimate (see `staff_create_delivery` in the delivery module migration) —
/// not a real routing engine. Orders are added in the order the staff member
/// picked them; that becomes the stop sequence.
///
/// Every candidate's customer pin is on one map with the branch, so nearby
/// orders can be grouped (tap a pin to add / remove it); the picked ones are
/// numbered in stop order. Orders without a pin are flagged and can only be
/// dispatched after an explicit confirmation. A registered driver of the
/// branch can be assigned right away (they accept the run in their app).
class CreateDeliveryScreen extends StatelessWidget {
  const CreateDeliveryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StaffDataScope(builder: (context, store) => _CreateDeliveryBody(store: store));
  }
}

class _CreateDeliveryBody extends StatefulWidget {
  final StaffStore store;
  const _CreateDeliveryBody({required this.store});

  @override
  State<_CreateDeliveryBody> createState() => _CreateDeliveryBodyState();
}

class _CreateDeliveryBodyState extends State<_CreateDeliveryBody> {
  final _formKey = GlobalKey<FormState>();
  final _vehicleController = TextEditingController();
  final _riderController = TextEditingController();

  bool _loadingOrders = true;
  Object? _loadError;
  List<DeliverableOrder> _orders = const [];

  /// Picked order ids, in the order the staff member tapped them — that
  /// order becomes the stop sequence.
  final List<String> _selectedOrderIds = [];

  /// Registered drivers of this branch (best effort: an older server or a
  /// branch without drivers simply offers none).
  List<BranchDriver> _drivers = const [];
  String? _driverUid;

  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  @override
  void dispose() {
    _vehicleController.dispose();
    _riderController.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    final branchId = widget.store.activeBranchId;
    if (branchId == null) {
      setState(() {
        _loadingOrders = false;
        _loadError = const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
      });
      return;
    }
    setState(() {
      _loadingOrders = true;
      _loadError = null;
    });
    unawaited(_loadDrivers(branchId));
    try {
      final orders = await DeliveryRepository.instance.listDeliverableOrders(branchId);
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _selectedOrderIds.removeWhere((id) => orders.every((o) => o.orderId != id));
        _loadingOrders = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loadingOrders = false;
      });
    }
  }

  Future<void> _loadDrivers(String branchId) async {
    try {
      final drivers = await DeliveryRepository.instance.listDrivers(branchId);
      if (!mounted) return;
      setState(() => _drivers = drivers.where((d) => d.isActive).toList());
    } catch (_) {}
  }

  BranchDriver? get _driver {
    for (final d in _drivers) {
      if (d.firebaseUid == _driverUid) return d;
    }
    return null;
  }

  void _pickDriver(String? uid) {
    setState(() {
      _driverUid = uid;
      final d = _driver;
      if (d != null) {
        _riderController.text = d.fullName;
        if (_vehicleController.text.trim().isEmpty && (d.vehicle ?? '').isNotEmpty) _vehicleController.text = d.vehicle!;
      }
    });
  }

  void _toggle(String orderId) {
    setState(() {
      if (_selectedOrderIds.contains(orderId)) {
        _selectedOrderIds.remove(orderId);
      } else {
        _selectedOrderIds.add(orderId);
      }
    });
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedOrderIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one order for this delivery.')),
      );
      return;
    }
    final branchId = widget.store.activeBranchId;
    if (branchId == null) return;

    // Orders without a customer pin are never dispatched silently.
    final unpinned = _orders.where((o) => _selectedOrderIds.contains(o.orderId) && !o.isPinned).toList();
    if (unpinned.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${unpinned.length} order${unpinned.length == 1 ? ' has' : 's have'} no map pin'),
          content: Text(
            '${unpinned.map((o) => '${o.orderId} (${o.customerName})').join(', ')}\n\n'
            'The rider will only have the address text and must call the customer. Dispatch anyway?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Dispatch anyway')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _creating = true);
    try {
      var delivery = await DeliveryRepository.instance.createDelivery(
        branchId: branchId,
        vehicle: _vehicleController.text.trim(),
        riderName: _riderController.text.trim(),
        orderIds: _selectedOrderIds,
      );
      final driver = _driver;
      if (driver != null) {
        try {
          delivery = await DeliveryRepository.instance.assignDriver(delivery.id, driver.firebaseUid);
        } catch (e) {
          // The run exists; the driver can be assigned again from its details.
          if (mounted) AppErrors.showSnack(context, e);
        }
      }
      widget.store.applyDelivery(delivery);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.routeOptimization, arguments: delivery);
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      AppErrors.showSnack(context, e);
    }
  }

  /// All candidates' pins with the branch: picked orders numbered in stop
  /// order (with the route line), the others grey "+" — tap to add/remove.
  Widget _candidatesMap() {
    double? branchLat;
    double? branchLng;
    for (final b in kBranches) {
      if (b.id == widget.store.activeBranchId) {
        branchLat = b.latitude;
        branchLng = b.longitude;
      }
    }
    final picked = [
      for (final id in _selectedOrderIds)
        for (final o in _orders)
          if (o.orderId == id && o.isPinned) o,
    ];
    final others = [for (final o in _orders) if (!_selectedOrderIds.contains(o.orderId) && o.isPinned) o];
    final stops = <MapStop>[
      for (final o in picked)
        MapStop(
          point: DeliveryMap.point(o.latitude, o.longitude)!,
          label: '${_selectedOrderIds.indexOf(o.orderId) + 1}. ${o.customerName} • ${o.orderId}',
          number: _selectedOrderIds.indexOf(o.orderId) + 1,
          onTap: () => _toggle(o.orderId),
        ),
      for (final o in others)
        MapStop(
          point: DeliveryMap.point(o.latitude, o.longitude)!,
          label: '${o.customerName} • ${o.orderId} (tap to add)',
          faded: true,
          onTap: () => _toggle(o.orderId),
        ),
    ];
    final unpinned = _orders.where((o) => !o.isPinned).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stops.isNotEmpty || DeliveryMap.point(branchLat, branchLng) != null)
          DeliveryMap(
            branch: DeliveryMap.point(branchLat, branchLng),
            branchLabel: widget.store.activeBranchName,
            stops: stops,
            height: 260,
          ),
        if (unpinned > 0)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: NoPinNotice(
              text: '$unpinned order${unpinned == 1 ? '' : 's'} without a customer pin (not on the map). '
                  'You will be asked to confirm before dispatching them.',
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Create Delivery', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(AppSpacing.radiusMd), border: Border.all(color: AppColors.border)),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Stop distance/time is a simple estimate — there is no real routing engine behind this.',
                        style: AppTextStyles.bodyMd,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Dispatch From', style: AppTextStyles.headlineSm),
              const SizedBox(height: 4),
              Text(
                widget.store.activeBranchName.isEmpty ? 'No branch selected' : widget.store.activeBranchName,
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      label: 'Vehicle',
                      controller: _vehicleController,
                      prefixIcon: Icons.local_shipping_outlined,
                      hint: 'e.g. Laguna Van #04',
                      validator: (v) => ValidationUtils.validateRequired(v, 'Vehicle'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_drivers.isNotEmpty) ...[
                DropdownButtonFormField<String?>(
                  initialValue: _driverUid,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Registered driver (optional)',
                    prefixIcon: Icon(Icons.delivery_dining_outlined),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('None — type a rider name below')),
                    for (final d in _drivers)
                      DropdownMenuItem<String?>(
                        value: d.firebaseUid,
                        child: Text(
                          '${d.fullName} • ${d.isAvailable ? 'available' : 'off duty'}'
                          '${d.activeRuns > 0 ? ' • ${d.activeRuns} open run${d.activeRuns == 1 ? '' : 's'}' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _pickDriver,
                ),
                const SizedBox(height: 12),
              ],
              AppTextField(
                label: 'Rider Name',
                controller: _riderController,
                prefixIcon: Icons.badge_outlined,
                hint: 'e.g. Juan dela Cruz',
                validator: (v) => ValidationUtils.validateName(v, 'Rider name'),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Orders to Deliver', style: AppTextStyles.headlineSm),
                  Text('${_selectedOrderIds.length} selected', style: AppTextStyles.bodySm),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_loadingOrders)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: StateLoadingView(message: 'Loading deliverable orders…', compact: true),
                )
              else if (_loadError != null)
                StateErrorView(error: _loadError, onRetry: _loadOrders, compact: true)
              else if (_orders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No confirmed delivery orders are waiting at this branch right now.',
                    style: AppTextStyles.bodyMd,
                  ),
                )
              else ...[
                _candidatesMap(),
                const SizedBox(height: AppSpacing.sm),
                for (final order in _orders)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _OrderTile(
                      order: order,
                      selected: _selectedOrderIds.contains(order.orderId),
                      sequenceNumber: _selectedOrderIds.indexOf(order.orderId) + 1,
                      onTap: () => _toggle(order.orderId),
                    ),
                  ),
              ],
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Create Delivery',
                icon: Icons.add_road_rounded,
                loading: _creating,
                onPressed: _creating ? null : _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final DeliverableOrder order;
  final bool selected;
  final int sequenceNumber;
  final VoidCallback onTap;

  const _OrderTile({
    required this.order,
    required this.selected,
    required this.sequenceNumber,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryContainer.withValues(alpha: 0.3) : Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary : AppColors.surfaceContainerLow,
                shape: BoxShape.circle,
              ),
              child: selected
                  ? Text('$sequenceNumber', style: AppTextStyles.labelMd.copyWith(color: Colors.white))
                  : const Icon(Icons.receipt_long_outlined, size: 14, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(order.customerName, style: AppTextStyles.labelLg)),
                      Text(order.orderId, style: AppTextStyles.bodySm),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(order.address, style: AppTextStyles.bodySm, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Row(
                    children: [
                      Icon(order.isPinned ? Icons.location_on_rounded : Icons.wrong_location_outlined,
                          size: 14, color: order.isPinned ? AppColors.success : AppColors.warning),
                      const SizedBox(width: 4),
                      Text(order.isPinned ? 'Pinned on the map' : 'No map pin — call before dispatch',
                          style: AppTextStyles.bodySm.copyWith(color: order.isPinned ? AppColors.success : AppColors.warning)),
                    ],
                  ),
                  if (order.items.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(order.items.join(', '), style: AppTextStyles.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
