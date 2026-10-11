import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/routes.dart';
import '../../../core/services/driver_location_tracker.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/services/permission_service.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../core/widgets/secondary_button.dart';
import '../../../data/models/delivery.dart';
import '../../../data/repositories/driver_repository.dart';
import '../../../data/repositories/route_eta_repository.dart';
import '../../settings/screens/logout_confirmation_screen.dart';
import '../widgets/run_map_card.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Home screen for a registered delivery driver.
///
/// Everything here is live from the database through [DriverRepository]:
/// runs assigned to this driver, accept / reject, pick-up, each stop's
/// outcome (with proof and cash collection), and optional live location
/// while carrying a run. Every stop shows the customer's pin on the run map
/// (numbered, next stop highlighted, with the driver's own position while
/// sharing); Navigate opens Google Maps, Waze or Apple Maps on the pin and
/// Call rings the customer — both only while the stop and run are open (the
/// server hides address, pin and phone afterwards).
class DriverPortalScreen extends StatefulWidget {
  const DriverPortalScreen({super.key});

  @override
  State<DriverPortalScreen> createState() => _DriverPortalScreenState();
}

class _DriverPortalScreenState extends State<DriverPortalScreen> {
  int _tab = 0;
  DriverContext? _context;
  List<Delivery> _active = const [];
  List<Delivery> _history = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  final _repo = DriverRepository.instance;
  final _tracker = DriverLocationTracker.instance;

  /// Road distance / time of the run on screen (route-eta Edge Function), read
  /// once per run and stop list.
  Future<RoadEta?>? _eta;
  String? _etaFor;

  Future<RoadEta?> _etaOf(Delivery d) {
    final key = '${d.id}|${d.stops.map((s) => '${s.latitude},${s.longitude}').join(';')}';
    if (_etaFor != key || _eta == null) {
      _etaFor = key;
      _eta = RouteEtaRepository.instance.forRun(d).catchError((Object e, StackTrace st) {
        AppErrors.report(e, st, 'driver_portal:road_eta');
        return null;
      });
    }
    return _eta!;
  }

  @override
  void initState() {
    super.initState();
    _tracker.addListener(_onTracker);
    _load();
  }

  @override
  void dispose() {
    _tracker.removeListener(_onTracker);
    super.dispose();
  }

  void _onTracker() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ctx = await _repo.getMyContext();
      List<Delivery> active = const [];
      List<Delivery> history = const [];
      if (ctx.isActive) {
        final all = await _repo.myDeliveries(includeFinished: true);
        active = all.where((d) => d.status.isActive).toList();
        history = all.where((d) => !d.status.isActive).toList();
      }
      if (!mounted) return;
      setState(() {
        _context = ctx;
        _active = active;
        _history = history;
        _loading = false;
      });
      // Stop sharing if the run we were sharing is no longer being carried.
      final shared = _tracker.deliveryId;
      if (shared != null && !active.any((d) => d.id == shared && _carrying(d))) {
        await _tracker.stop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppErrors.from(e).message;
        _loading = false;
      });
    }
  }

  bool _carrying(Delivery d) => d.driverStatus == 'picked_up' || d.driverStatus == 'in_transit';

  /// Runs [action], shows its error (database messages are written for
  /// drivers), then reloads.
  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (done != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppErrors.from(e).message), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.roleDelivery,
              child: Icon(Icons.local_shipping_rounded, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Driver', style: AppTextStyles.labelLg),
                  Text(_context?.branchName ?? '—', style: AppTextStyles.bodySm, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route_rounded), label: 'My runs'),
          NavigationDestination(icon: Icon(Icons.history_rounded), label: 'History'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _context == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _context == null) {
      return _Message(icon: Icons.cloud_off_rounded, text: _error!, actionLabel: 'Try again', onAction: _load);
    }
    final ctx = _context!;
    if (!ctx.isActive) {
      return _Message(
        icon: Icons.lock_outline_rounded,
        text: ctx.statusMessage,
        actionLabel: 'Log out',
        onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen())),
      );
    }
    switch (_tab) {
      case 0:
        return RefreshIndicator(onRefresh: _load, child: _activeTab(ctx));
      case 1:
        return RefreshIndicator(onRefresh: _load, child: _historyTab());
      default:
        return _profileTab(ctx);
    }
  }

  Widget _activeTab(DriverContext ctx) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _Card(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Available for deliveries', style: AppTextStyles.labelLg),
            subtitle: Text('The branch sees this when assigning runs.', style: AppTextStyles.bodySm),
            value: ctx.isAvailable,
            onChanged: _busy ? null : (v) => _run(() async => _repo.setAvailability(v)),
          ),
        ),
        if (_tracker.problem != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _Banner(text: _tracker.problem!, color: AppColors.warningBg),
        ],
        const SizedBox(height: AppSpacing.md),
        if (_active.isEmpty)
          const _Message(icon: Icons.inbox_outlined, text: 'No runs assigned to you right now.')
        else
          ..._active.map(_runCard),
      ],
    );
  }

  Widget _runCard(Delivery d) {
    final status = d.driverStatus ?? 'assigned';
    final carrying = _carrying(d);
    final sharing = _tracker.deliveryId == d.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(d.id, style: AppTextStyles.titleMd)),
                _Chip(label: _statusLabel(status), color: carrying ? AppColors.success : AppColors.primary),
              ],
            ),
            const SizedBox(height: 4),
            Text('${d.branch} • ${d.vehicle} • ${d.stops.length} stop${d.stops.length == 1 ? '' : 's'}',
                style: AppTextStyles.bodySm),
            const SizedBox(height: AppSpacing.sm),
            if (status == 'assigned') ...[
              PrimaryButton(
                label: 'Accept run',
                icon: Icons.check_rounded,
                loading: _busy,
                onPressed: () => _run(() async => _repo.accept(d.id), done: 'Run accepted.'),
              ),
              const SizedBox(height: AppSpacing.xs),
              SecondaryButton(label: 'Reject', icon: Icons.close_rounded, onPressed: _busy ? null : () => _reject(d)),
            ] else if (status == 'accepted') ...[
              Text('Collect the parcels at the branch, then confirm the pick-up.', style: AppTextStyles.bodySm),
              const SizedBox(height: AppSpacing.xs),
              PrimaryButton(
                label: 'Picked up at branch',
                icon: Icons.inventory_2_outlined,
                loading: _busy,
                onPressed: () => _run(() async => _repo.markPickedUp(d.id), done: 'Pick-up confirmed. Drive safely!'),
              ),
              const SizedBox(height: AppSpacing.xs),
              SecondaryButton(label: 'Reject', icon: Icons.close_rounded, onPressed: _busy ? null : () => _reject(d)),
            ] else if (carrying) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Share my location', style: AppTextStyles.labelLg),
                subtitle: Text(
                  'Only while this run is out, so the branch and your customers can follow it. Stops automatically when the run ends.',
                  style: AppTextStyles.bodySm,
                ),
                value: sharing,
                onChanged: (v) async {
                  if (v) {
                    final agreed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(AppLocalizations.of(ctx).shareLocationQuestion),
                        content: const Text(DriverLocationTracker.backgroundRationale),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(AppLocalizations.of(ctx).notNow)),
                          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(AppLocalizations.of(ctx).shareForThisRun)),
                        ],
                      ),
                    );
                    if (agreed != true) return;
                    final started = await _tracker.start(d.id);
                    if (!started && mounted) {
                      // Explain what will not work; Try again / Open Settings.
                      final retry = await PermissionDeniedDialog.show(
                        context,
                        AppPermission.location,
                        PermissionPurpose.deliveryTracking,
                        permanentlyDenied: _tracker.permissionBlocked,
                      );
                      if (retry) await _tracker.start(d.id);
                    }
                  } else {
                    await _tracker.stop();
                  }
                },
              ),
            ],
            _runMap(d, sharing),
            const Divider(height: AppSpacing.lg),
            ...d.stops.map((s) => _stopTile(d, s, carrying)),
          ],
        ),
      ),
    );
  }

  /// Branch, every customer pin in stop order (the next stop highlighted)
  /// and, while sharing, my own position. Stops without a pin are listed
  /// under the map with a "call them" notice; nothing is drawn at 0,0.
  Widget _runMap(Delivery d, bool sharing) {
    final me = sharing ? _tracker.lastPosition : null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RunMapCard(
            delivery: d,
            driver: me == null ? null : DeliveryMap.point(me.latitude, me.longitude),
            driverLabel: 'You',
            height: 220,
            onStopTap: (s) => Navigator.of(context).pushNamed(AppRoutes.routeMap, arguments: {'delivery': d, 'stopId': s.id}),
          ),
          FutureBuilder<RoadEta?>(
            future: _etaOf(d),
            builder: (context, snap) {
              final eta = snap.data;
              if (eta == null) return const SizedBox.shrink(); // not configured / no pins: no road figure
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.route_rounded, size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(child: Text(eta.label, style: AppTextStyles.bodySm)),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _stopTile(Delivery d, DeliveryStop s, bool carrying) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: s.status.color.withValues(alpha: 0.15),
                child: Text('${s.sequenceIndex + 1}', style: AppTextStyles.labelMd.copyWith(color: s.status.color)),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: Text(s.customerName, style: AppTextStyles.labelLg)),
              _Chip(label: s.status.label, color: s.status.color),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.address, style: AppTextStyles.bodySm),
                if (s.items.isNotEmpty) Text(s.items.join(', '), style: AppTextStyles.bodySm),
                if ((s.customerNotes ?? '').isNotEmpty) Text('Note: ${s.customerNotes}', style: AppTextStyles.bodySm),
                if (s.orderTotal != null)
                  Text(
                    s.needsCashCollection
                        ? 'Collect cash: ${peso(s.orderTotal!)}'
                        : 'Paid (${(s.paymentMethod ?? '').toUpperCase()}) • ${peso(s.orderTotal!)}',
                    style: AppTextStyles.labelMd.copyWith(
                      color: s.needsCashCollection ? AppColors.warning : AppColors.success,
                    ),
                  ),
                if (s.issueReason != null && s.status == StopStatus.failed)
                  Text('Reason: ${s.issueReason}', style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
                if (!s.isFinished) ...[
                  const SizedBox(height: AppSpacing.xs),
                  StopNavigationActions(
                    delivery: d,
                    stop: s,
                    trailing: [
                      if (carrying && s.status == StopStatus.pending)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(() async => _repo.startStop(s.id)),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('On my way'),
                        ),
                      if (carrying)
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _deliver(d, s),
                          icon: const Icon(Icons.check_circle_outline, size: 18),
                          label: const Text('Delivered'),
                        ),
                      if (carrying)
                        TextButton.icon(
                          onPressed: _busy ? null : () => _fail(s),
                          icon: const Icon(Icons.report_outlined, size: 18, color: AppColors.error),
                          label: const Text('Failed', style: TextStyle(color: AppColors.error)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reject(Delivery d) async {
    final reason = await _askText(
      title: 'Reject this run?',
      label: 'Reason (the branch will see this)',
      action: 'Reject run',
    );
    if (reason == null) return;
    await _run(() => _repo.reject(d.id, reason), done: 'Run returned to the branch.');
  }

  Future<void> _fail(DeliveryStop s) async {
    final reason = await _askText(
      title: 'Delivery failed',
      label: 'What happened? (e.g. nobody home, wrong address)',
      action: 'Return to branch',
    );
    if (reason == null) return;
    await _run(() async => _repo.markFailed(stopId: s.id, reason: reason), done: 'Marked as failed. Bring the order back to the branch.');
  }

  Future<void> _deliver(Delivery d, DeliveryStop s) async {
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final cashCtrl = TextEditingController(text: s.needsCashCollection && s.orderTotal != null ? s.orderTotal!.toStringAsFixed(2) : '');
    final formKey = GlobalKey<FormState>();
    List<int>? photo;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
       builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Confirm delivery'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Proof photo (optional): the parcel at the door / with the customer.
                Row(
                  children: [
                    if (photo != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(Uint8List.fromList(photo!), width: 64, height: 64, fit: BoxFit.cover),
                      ),
                    if (photo != null) const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(photo == null ? 'Take proof photo' : 'Retake photo'),
                        onPressed: () async {
                          final shot = await _takeProofPhoto();
                          if (shot != null) setDialog(() => photo = shot);
                        },
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: nameCtrl,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.name],
                  maxLength: InputLimits.name,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  decoration: const InputDecoration(labelText: 'Received by (name)', counterText: ''),
                  validator: (v) => ValidationUtils.validateName(v, 'Receiver name'),
                ),
                if (s.needsCashCollection)
                  TextFormField(
                    controller: cashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: InputRules.decimal(),
                    decoration: InputDecoration(labelText: 'Cash collected (${peso(s.orderTotal ?? 0)} due)'),
                    validator: (v) => ValidationUtils.validateNumber(
                      v,
                      fieldName: 'Cash collected',
                      min: 0,
                      max: 1000000,
                    ),
                  ),
                TextFormField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: 'Note (optional)'),
                  maxLength: 200,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  validator: (v) => ValidationUtils.validateText(v, fieldName: 'Note', maxLength: 200),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true);
            },
            child: const Text('Confirm'),
          ),
        ],
       ),
      ),
    );
    final recipientName = nameCtrl.text.trim();
    final noteText = noteCtrl.text.trim();
    final cashText = cashCtrl.text.trim();
    disposeAfterDialog([nameCtrl, noteCtrl, cashCtrl]);
    if (confirmed != true) return;
    await _run(
      () async => _repo.markDelivered(
        stopId: s.id,
        // Upload first; the stop then points at the private file. If the
        // upload fails, nothing is marked delivered and the driver can retry.
        proofPhotoPath: photo == null
            ? null
            : await _repo.uploadProofPhoto(deliveryId: d.id, stopId: s.id, bytes: photo!),
        recipientName: recipientName,
        note: noteText.isEmpty ? null : noteText,
        cashCollected: s.needsCashCollection ? double.tryParse(cashText) : null,
      ),
      done: 'Delivered. Thank you!',
    );
  }

  /// Largest proof photo that is uploaded (after compression).
  static const int _maxPhotoBytes = 1024 * 1024; // ~1 MB

  /// Camera photo, downscaled to at most 1280 px and JPEG quality 80 (usually
  /// 200–500 KB) before upload. The camera permission is explained first; a
  /// refusal is handled with Try again / Open Settings.
  Future<List<int>?> _takeProofPhoto() async {
    final go = await PermissionService.instance.beforeCamera(context, PermissionPurpose.proofPhoto);
    if (!go || !mounted) return null;
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );
      if (file == null) return null;
      await PermissionService.instance.cameraGranted();
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxPhotoBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('The photo is larger than 1 MB. Please take it again, a little further away.')));
        }
        return null;
      }
      return bytes;
    } on PlatformException catch (e, st) {
      if (e.code == 'camera_access_denied' || e.code == 'camera_access_restricted') {
        if (mounted) {
          final retry = await PermissionService.instance.cameraDenied(context, PermissionPurpose.proofPhoto);
          if (retry && mounted) return _takeProofPhoto();
        }
        return null;
      }
      AppErrors.report(e, st, 'driver_portal_screen:takeProofPhoto');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The camera could not be opened.')));
      }
      return null;
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'driver_portal_screen:506');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The camera could not be opened.')));
      }
      return null;
    }
  }

  Future<String?> _askText({required String title, required String label, required String action}) async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            maxLength: InputLimits.shortReason,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(labelText: label),
            validator: (v) => ValidationUtils.validateReason(
              v,
              minLength: InputLimits.shortReasonMin,
              maxLength: InputLimits.shortReason,
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true);
            },
            child: Text(action),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    disposeAfterDialog([ctrl]);
    return ok == true ? text : null;
  }

  Widget _historyTab() {
    if (_history.isEmpty) {
      return ListView(children: const [_Message(icon: Icons.history_rounded, text: 'Finished runs will show here.')]);
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: _history.map((d) {
        final delivered = d.stops.where((s) => s.status == StopStatus.delivered).length;
        final failed = d.stops.where((s) => s.status == StopStatus.failed).length;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: _Card(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(d.id, style: AppTextStyles.labelLg),
              subtitle: Text(
                '${d.branch} • $delivered delivered${failed > 0 ? ' • $failed failed' : ''}',
                style: AppTextStyles.bodySm,
              ),
              trailing: _Chip(label: d.status.label, color: d.status.color),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _profileTab(DriverContext ctx) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ctx.fullName ?? '—', style: AppTextStyles.headlineSm),
              const SizedBox(height: AppSpacing.xs),
              Text(ctx.email ?? '', style: AppTextStyles.bodyMd),
              if ((ctx.phone ?? '').isNotEmpty) Text(ctx.phone!, style: AppTextStyles.bodyMd),
              const Divider(height: AppSpacing.lg),
              Text('Branch: ${ctx.branchName ?? '—'}', style: AppTextStyles.bodyMd),
              Text('Vehicle: ${ctx.vehicle ?? '—'}', style: AppTextStyles.bodyMd),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SecondaryButton(
          label: 'Log Out',
          icon: Icons.logout_rounded,
          onPressed: () async {
            await _tracker.stop();
            if (!mounted) return;
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LogoutConfirmationScreen()));
          },
        ),
      ],
    );
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'assigned':
        return 'New';
      case 'accepted':
        return 'Accepted';
      case 'picked_up':
        return 'Picked up';
      case 'in_transit':
        return 'On the road';
      case 'completed':
        return 'Done';
      default:
        return s;
    }
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: AppTextStyles.labelMd.copyWith(color: color)),
      );
}

class _Banner extends StatelessWidget {
  final String text;
  final Color color;
  const _Banner({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppSpacing.radiusSm)),
        child: Text(text, style: AppTextStyles.bodySm),
      );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _Message({required this.icon, required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.sm),
            Text(text, textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.md),
              PrimaryButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      );
}
