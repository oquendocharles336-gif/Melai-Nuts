import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/branch_controller.dart';
import '../../../core/services/checkout_attempt_store.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/customer_data_store.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/geo_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/widgets/delivery_map.dart';
import '../../../core/widgets/location_picker.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/customer_profile.dart';
import '../../../data/repositories/orders_repository.dart';
import '../../../data/repositories/customer_profile_repository.dart';
import '../../../data/repositories/payment_settings_repository.dart';
import '../../../data/repositories/payments_repository.dart';
import '../../../data/repositories/products_repository.dart';
import '../../payments/screens/online_payment_screen.dart';
import '../../settings/screens/branch_settings_screen.dart';
import '../cart_controller.dart';
import '../widgets/online_payment_unavailable_notice.dart';
import 'order_confirmation_screen.dart';
import '../../../l10n/generated/app_localizations.dart';

enum _FulfillmentMethod { pickup, delivery }

/// `online` is HitPay's hosted checkout (GCash, Maya, cards). `cod` is only
/// valid for delivery and `cash` (pay at the counter) only for pickup.
enum _PaymentMethod { online, cod, cash }

/// Checkout — fulfillment method, branch/pickup details, payment method,
/// and order summary. Order totals, stock, discounts, and cart consumption
/// are finalized by the Supabase order transaction.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  _FulfillmentMethod _fulfillment = _FulfillmentMethod.pickup;
  // Online payment is OFF by the owner's decision (PaymentConfig + the
  // database switch): start on the cash option of the default fulfillment.
  _PaymentMethod _payment = _PaymentMethod.cash;

  /// The database's online-payment switch and message; [PaymentSettings.unknown]
  /// (= off) until it has been read, or when it cannot be read.
  PaymentSettings _paymentSettings = PaymentSettings.unknown;
  bool get _onlineAllowed => _paymentSettings.onlineAllowed;
  final _notesController = TextEditingController();
  final _addressController = TextEditingController();
  final _contactController = TextEditingController();
  bool _placingOrder = false;
  String? _deliveryAddressId;

  /// The delivery pin the customer confirms here. It is saved on the address
  /// and copied onto the order by the database, so staff and the rider see
  /// exactly this point. A delivery order cannot be placed without it.
  double? _pinLat;
  double? _pinLng;

  // The idempotency key for this checkout is NOT held in memory: it is
  // persisted by CheckoutAttemptStore (one key per customer + cart) so a
  // retry after a dropped connection *or an app restart* reuses it and can
  // never create a second order. It is only cleared once the server has
  // accepted the order (retrying with the same key is always safe).

  @override
  void initState() {
    super.initState();
    final address = CustomerDataStore.instance.defaultAddress;
    if (address != null) _useAddress(address);
    unawaited(_loadPaymentSettings());
  }

  Future<void> _loadPaymentSettings() async {
    try {
      final settings = await PaymentSettingsRepository.instance.fetch();
      if (mounted) setState(() => _paymentSettings = settings);
    } catch (e) {
      // Unreadable switch = online payment stays off; the built-in text is shown.
      if (kDebugMode) debugPrint('payment_settings could not be read: $e');
    }
  }

  void _useAddress(CustomerAddress address) {
    _deliveryAddressId = address.id;
    _addressController.text = address.fullAddress;
    _contactController.text = address.phone;
    _pinLat = address.isPinned ? address.latitude : null;
    _pinLng = address.isPinned ? address.longitude : null;
  }

  Future<void> _chooseSavedAddress() async {
    final addresses = CustomerDataStore.instance.addresses;
    if (addresses.isEmpty) return;
    final picked = await showModalBottomSheet<CustomerAddress>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final a in addresses)
              ListTile(
                leading: Icon(a.isPinned ? Icons.location_on_rounded : Icons.wrong_location_outlined,
                    color: a.isPinned ? AppColors.primary : AppColors.warning),
                title: Text(a.label),
                subtitle: Text(a.isPinned ? a.fullAddress : '${a.fullAddress}\nNo map pin yet', maxLines: 3),
                onTap: () => Navigator.of(ctx).pop(a),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _useAddress(picked));
  }

  /// One-tap "Pin on map" (also offered by the blocking message).
  Future<void> _pinOnMap() async {
    final branch = BranchController.instance.selectedBranch;
    final picked = await LocationPickerScreen.open(
      context,
      initialLatitude: _pinLat,
      initialLongitude: _pinLng,
      fallbackLatitude: branch?.latitude,
      fallbackLongitude: branch?.longitude,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pinLat = picked.latitude;
      _pinLng = picked.longitude;
      if (_addressController.text.trim().isEmpty && (picked.address?.displayName ?? '').isNotEmpty) {
        _addressController.text = picked.address!.displayName;
        _deliveryAddressId = null;
      }
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    _addressController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    final cart = CartController.instance;
    if (cart.lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your cart is empty.')),
      );
      return;
    }
    if (_placingOrder) return; // no double submit
    if (!FormUtils.validateAndFocus(_formKey)) {
      return;
    }
    // Fail fast and honestly: don't let the person sit through a doomed
    // request, and never let a checkout attempt start believing it might
    // silently "queue" — there is no offline order queue. Placing an order
    // always requires reaching the real backend right now.
    if (!ConnectivityService.instance.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You\'re offline. Please reconnect before placing your order — nothing has been charged or ordered yet.'),
        ),
      );
      return;
    }
    final firebaseUid = AuthService.instance.currentFirebaseUser?.uid;
    if (firebaseUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in again before checking out.')),
      );
      return;
    }
    final branch = BranchController.instance.selectedBranch;
    if (branch == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a branch before checking out.')),
      );
      return;
    }
    // Staff need a real number to reach the customer for both pickup and
    // delivery orders. Delivery collects one via the contact field below;
    // pickup relies on the profile's phone, so check it up front rather
    // than letting the RPC reject the order after everything else already
    // validated. (The RPC still enforces this itself — this is just a
    // faster, friendlier failure for the common case of an incomplete
    // profile.)
    if (_fulfillment == _FulfillmentMethod.pickup) {
      final profilePhone = CustomerDataStore.instance.profile?.phone.trim() ?? '';
      if (profilePhone.isEmpty) {
        // Let the customer add it right here instead of leaving checkout.
        final saved = await _promptForContactPhone(firebaseUid);
        if (!saved || !mounted) return;
      }
    }

    // Online payment is off (owner decision; the database refuses it too).
    if (_payment == _PaymentMethod.online && !_onlineAllowed) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_paymentSettings.unavailableMessage)));
      return;
    }

    // Riders find customers by the pin: no delivery order without a valid one.
    final pinProblem = GeoUtils.deliveryPinProblem(
      isDelivery: _fulfillment == _FulfillmentMethod.delivery,
      lat: _pinLat,
      lng: _pinLng,
    );
    if (pinProblem != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(pinProblem),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Pin on map', onPressed: _pinOnMap),
        ));
      return;
    }

    setState(() => _placingOrder = true);

    final payOnline = _payment == _PaymentMethod.online;
    final paymentLabel = switch (_payment) {
      _PaymentMethod.online => 'Online Payment (GCash, Maya, Card)',
      _PaymentMethod.cod => 'Cash on Delivery',
      _PaymentMethod.cash => 'Cash on Counter Pickup',
    };

    try {
      final cartId = cart.cartId;
      if (cartId == null) {
        throw const AppError(
          AppErrorKind.orderFailed,
          'Your cart is not synced yet. Please check your connection and try again.',
        );
      }
      final isDelivery = _fulfillment == _FulfillmentMethod.delivery;
      String? deliveryAddressId = _deliveryAddressId;
      if (isDelivery) {
        final enteredAddress = _addressController.text.trim();
        // One stored phone format (E.164) — compare normalized numbers.
        final enteredPhone = ValidationUtils.normalizePhone(_contactController.text);
        final matching = CustomerDataStore.instance.addresses.where(
          (address) =>
              address.fullAddress.trim() == enteredAddress &&
              ValidationUtils.normalizePhone(address.phone) == enteredPhone,
        );
        if (matching.isNotEmpty) {
          final saved = matching.first;
          deliveryAddressId = saved.id;
          // The customer (re)pinned it here: save the pin on the address first —
          // the order copies the address's pin when it is placed.
          if (saved.latitude != _pinLat || saved.longitude != _pinLng) {
            final updated = await AppErrors.guard(
              () => CustomerProfileRepository.instance.updateAddressPin(
                id: saved.id,
                firebaseUid: firebaseUid,
                latitude: _pinLat!,
                longitude: _pinLng!,
              ),
              scope: ErrorScope.address,
            );
            CustomerDataStore.instance.setAddresses([
              for (final a in CustomerDataStore.instance.addresses) a.id == updated.id ? updated : a,
            ]);
          }
        } else {
          final profile = CustomerDataStore.instance.profile;
          if (profile == null) {
            throw const AppError(
              AppErrorKind.notFound,
              'Your customer profile is not ready yet. Please try again.',
            );
          }
          final saved = await AppErrors.guard(
            () => CustomerProfileRepository.instance.addAddress(
              firebaseUid: firebaseUid,
              label: 'Checkout',
              recipientName: profile.fullName,
              phone: enteredPhone,
              line1: enteredAddress,
              city: '',
              province: '',
              postalCode: '',
              isDefault: false,
              latitude: _pinLat,
              longitude: _pinLng,
            ),
            scope: ErrorScope.address,
          );
          deliveryAddressId = saved.id;
          CustomerDataStore.instance.setAddresses([
            ...CustomerDataStore.instance.addresses,
            saved,
          ]);
        }
      }
      final itemCount = cart.itemCount;
      final notes = _notesController.text.trim();
      // The server answers a repeated key with the FIRST order it stored and
      // never compares the request, so a key may only be reused for the
      // identical request. Everything that shapes the order goes in here.
      final fingerprint = jsonEncode([isDelivery, deliveryAddressId, if (isDelivery) _pinLat, if (isDelivery) _pinLng, paymentLabel, notes]);
      final CheckoutAttempt attempt;
      try {
        attempt = await CheckoutAttemptStore.instance.begin(
          uid: firebaseUid,
          cartId: cartId,
          fingerprint: fingerprint,
        );
      } on CheckoutAlreadyPlacedException catch (placed) {
        // The customer changed their options after a request whose outcome was
        // unknown, and the server had in fact accepted it. That earlier order
        // is the real one: show it rather than placing a second.
        await _quietly(() => cart.completeCheckout());
        unawaited(_quietly(() => CustomerDataStore.instance.refresh()));
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Your earlier order went through, so it was kept as placed. '
                  'Check its details below.'),
              duration: Duration(seconds: 6),
            ),
          );
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => OrderConfirmationScreen(
              order: placed.order,
              itemCount: itemCount,
              total: placed.order.total,
            ),
          ),
        );
        return;
      }
      // `place_order` creates the order, its items, and its payment record
      // together in one database transaction — there is no separate,
      // second network call to record the payment here, so a dropped
      // connection right after checkout can never leave an order with no
      // payment record behind.
      // From here until the server answers, the outcome is unknown; persist
      // that so an app kill mid-request is settled on the next launch.
      await CheckoutAttemptStore.instance.markSubmitted(attempt);
      final order = await OrdersRepository.instance.createOrderFromCart(
        cartId: cartId,
        isDelivery: isDelivery,
        deliveryAddressId: deliveryAddressId,
        paymentMethod: paymentLabel,
        customerNotes: notes,
        idempotencyKey: attempt.key,
      );

      // The server accepted the order — only now is it real, so only now is
      // the attempt (and its key) forgotten.
      await CheckoutAttemptStore.instance.clear();

      // The order is already placed at this point. A failure while tidying up
      // local state must never be reported to the customer as a failed order.
      await _quietly(() => cart.completeCheckout());
      unawaited(_quietly(() => CustomerDataStore.instance.refresh()));
      // The `place_order` RPC just decremented real stock server-side —
      // reload the catalog so kProducts (and every screen reading it)
      // reflects the new, real quantities instead of the pre-checkout
      // numbers still sitting in memory.
      unawaited(_quietly(() => ProductsRepository.instance.loadCatalog(branchId: branch.id)));

      if (payOnline) {
        // The order is saved and unpaid. If the payment page cannot be
        // opened, the next screen offers a "Pay now" retry; the order is
        // never lost.
        String? startError;
        try {
          final url = await PaymentsRepository.instance.startHitpayCheckout(order.id);
          final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          if (!opened) startError = 'We could not open the payment page. Please try again.';
        } catch (e) {
          startError = AppErrors.from(e, scope: ErrorScope.order).message;
        }
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => OnlinePaymentScreen(order: order, itemCount: itemCount, startError: startError),
          ),
        );
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              OrderConfirmationScreen(order: order, itemCount: itemCount, total: order.total),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // Customer-safe message for every failure (offline, timeout, expired
      // session, insufficient stock, unavailable product/branch, invalid
      // voucher, not enough points, payment failure, database error...).
      // For a dropped connection the wording says the order may have gone
      // through; tapping Place Order again re-uses the persisted attempt key, so
      // it can never create a duplicate.
      final error = AppErrors.from(e, scope: ErrorScope.order);
      if (error.isStockRelated) {
        // The cart no longer matches reality — reload real stock so the rest
        // of the app shows the true quantities.
        unawaited(_quietly(() => ProductsRepository.instance.loadCatalog(branchId: branch.id)));
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(error.message), duration: const Duration(seconds: 6)),
        );
    } finally {
      if (mounted) setState(() => _placingOrder = false);
    }
  }

  /// Runs best-effort follow-up work whose failure must not surface to the
  /// customer (and must not become an unhandled async error).
  Future<void> _quietly(Future<dynamic> Function() action) async {
    try {
      await action();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'checkout_screen:448');
    }
  }

  /// Asks for a contact phone inline and saves it to the customer's profile.
  /// Returns true once the profile has a phone.
  Future<bool> _promptForContactPhone(String firebaseUid) async {
    Future<void> save(String phone) async {
      final store = CustomerDataStore.instance;
      final account = AuthService.instance.currentProfile;
      final CustomerProfile current = store.profile ??
          await AppErrors.guard<CustomerProfile>(
            () => store.ensureProfile(
              firebaseUid: firebaseUid,
              fallbackName: account?.name ?? '',
              fallbackEmail: account?.email ?? '',
            ),
            scope: ErrorScope.profile,
          );
      final updated = await AppErrors.guard(
        () => CustomerProfileRepository.instance.updateProfile(
          firebaseUid: firebaseUid,
          fullName: current.fullName.trim().isNotEmpty ? current.fullName : (account?.name ?? ''),
          phone: phone,
        ),
        scope: ErrorScope.profile,
      );
      store.updateCachedProfile(updated);
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ContactPhoneDialog(onSave: save),
    );
    return saved == true;
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartController.instance;
    final profile = CustomerDataStore.instance.profile;
    final email = AuthService.instance.currentFirebaseUser?.email ?? profile?.email;
    final phone = profile?.phone;
    final branch = BranchController.instance.selectedBranch;
    // If the selected branch can't actually fulfil the currently chosen
    // method (e.g. it doesn't deliver), fall back to whichever method it
    // does support instead of silently charging for an unavailable one.
    if (branch != null) {
      if (_fulfillment == _FulfillmentMethod.delivery && !branch.supportsDelivery) {
        _fulfillment = _FulfillmentMethod.pickup;
      } else if (_fulfillment == _FulfillmentMethod.pickup && !branch.supportsPickup) {
        _fulfillment = _FulfillmentMethod.delivery;
      }
    }
    // Cash on Delivery needs delivery and Cash on Counter Pickup needs
    // pickup; if a fulfillment change made the choice invalid, switch to the
    // cash option of the chosen fulfillment (online payment is never picked
    // automatically).
    final cashForFulfillment = _fulfillment == _FulfillmentMethod.delivery ? _PaymentMethod.cod : _PaymentMethod.cash;
    if ((_fulfillment == _FulfillmentMethod.delivery && _payment == _PaymentMethod.cash) ||
        (_fulfillment == _FulfillmentMethod.pickup && _payment == _PaymentMethod.cod)) {
      _payment = cashForFulfillment;
    }
    if (_payment == _PaymentMethod.online && !_onlineAllowed) {
      _payment = cashForFulfillment;
    }
    final deliveryFee = _fulfillment == _FulfillmentMethod.delivery
        ? (branch?.deliveryFee ?? 0)
        : 0.0;
    final total = (cart.subtotal - cart.voucherDiscount - cart.loyaltyDiscount + deliveryFee)
        .clamp(0.0, double.infinity)
        .toDouble();

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: const MelaiAppBar(title: 'Checkout', showBack: true),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.sm,
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.badge_outlined, color: AppColors.darkBrown),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Customer Account', style: AppTextStyles.titleMd),
                        Text(
                          (phone == null || phone.isEmpty) ? 'No phone linked' : phone,
                          style: AppTextStyles.bodySm,
                        ),
                        Text(
                          (email == null || email.isEmpty) ? 'No email linked' : email,
                          style: AppTextStyles.bodySm,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Fulfillment Method', style: AppTextStyles.titleMd),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _OptionCard(
                    icon: Icons.storefront_outlined,
                    title: 'Store Pickup',
                    subtitle: 'Pick up at the branch counter',
                    trailingLabel: 'FREE',
                    selected: _fulfillment == _FulfillmentMethod.pickup,
                    onTap: (branch == null || branch.supportsPickup)
                        ? () => setState(() => _fulfillment = _FulfillmentMethod.pickup)
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _OptionCard(
                    icon: Icons.delivery_dining_rounded,
                    title: 'Melai Van',
                    subtitle: (branch != null && !branch.supportsDelivery)
                        ? 'Not offered at this branch'
                        : 'Delivered by Melai',
                    trailingLabel: branch == null ? '—' : '₱${branch.deliveryFee.toStringAsFixed(2)}',
                    selected: _fulfillment == _FulfillmentMethod.delivery,
                    onTap: (branch == null || branch.supportsDelivery)
                        ? () => setState(() => _fulfillment = _FulfillmentMethod.delivery)
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.primary, width: 1.4),
                boxShadow: AppShadows.sm,
              ),
              child: branch == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('NO BRANCH SELECTED', style: AppTextStyles.labelSm),
                        const SizedBox(height: 6),
                        Text(
                          'Pick a branch so we know where to fulfil this order from.',
                          style: AppTextStyles.bodySm,
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const BranchSettingsScreen()),
                          ),
                          child: const Text('Select Branch'),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _fulfillment == _FulfillmentMethod.pickup
                                  ? 'PICKUP DEPOT DETAILS'
                                  : 'FULFILLING FROM',
                              style: AppTextStyles.labelSm,
                            ),
                            if (branch.contactPhone != null && branch.contactPhone!.isNotEmpty)
                              Text(branch.contactPhone!, style: AppTextStyles.bodySm),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(branch.name, style: AppTextStyles.titleMd),
                        Text(branch.address, style: AppTextStyles.bodySm),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.access_time_rounded, size: 16, color: AppColors.textSecondary),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                branch.operatingHours ?? 'Hours not set',
                                style: AppTextStyles.bodySm,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
            if (_fulfillment == _FulfillmentMethod.delivery) ...[
              const SizedBox(height: AppSpacing.md),
              Text('Delivery Details', style: AppTextStyles.titleMd),
              const SizedBox(height: 8),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(
                  labelText: 'Delivery address',
                  hintText: 'House/unit no., street, barangay, city',
                ),
                keyboardType: TextInputType.streetAddress,
                autofillHints: const [AutofillHints.fullStreetAddress],
                textCapitalization: TextCapitalization.words,
                maxLength: InputLimits.address,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                maxLines: 2,
                onChanged: (_) => _deliveryAddressId = null,
                validator: (v) => ValidationUtils.validateAddress(v),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _contactController,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: InputRules.phone(),
                decoration: const InputDecoration(
                  labelText: 'Contact number for the rider',
                  hintText: '0917 123 4567',
                ),
                onChanged: (_) => _deliveryAddressId = null,
                validator: (v) => ValidationUtils.validatePhone(v),
              ),
              if (CustomerDataStore.instance.addresses.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _chooseSavedAddress,
                    icon: const Icon(Icons.bookmark_border_rounded, size: 18),
                    label: const Text('Use a saved address'),
                  ),
                ),
              const SizedBox(height: 8),
              _DeliveryPinReview(
                latitude: _pinLat,
                longitude: _pinLng,
                branchName: branch?.name,
                branchLatitude: branch?.latitude,
                branchLongitude: branch?.longitude,
                onPin: _pinOnMap,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text(AppLocalizations.of(context).paymentMethod, style: AppTextStyles.titleMd),
            const SizedBox(height: AppSpacing.sm),
            // Online payment (HitPay) is hidden while it is off; the notice text
            // comes from payment_settings.online_payment_disabled_message.
            if (_onlineAllowed) ...[
              _PaymentTile(
                icon: Icons.account_balance_wallet_rounded,
                title: 'Online Payment (GCash, Maya, Card)',
                subtitle: 'Pay securely on the HitPay payment page',
                selected: _payment == _PaymentMethod.online,
                onTap: () => setState(() => _payment = _PaymentMethod.online),
              ),
              const SizedBox(height: 8),
            ] else ...[
              OnlinePaymentUnavailableNotice(message: _paymentSettings.unavailableMessage),
              const SizedBox(height: 8),
            ],
            if (_fulfillment == _FulfillmentMethod.delivery)
              _PaymentTile(
                icon: Icons.delivery_dining_rounded,
                title: AppLocalizations.of(context).cashOnDelivery,
                subtitle: AppLocalizations.of(context).cashOnDeliverySubtitle,
                selected: _payment == _PaymentMethod.cod,
                onTap: () => setState(() => _payment = _PaymentMethod.cod),
              )
            else
              _PaymentTile(
                icon: Icons.storefront_rounded,
                title: AppLocalizations.of(context).cashOnPickup,
                subtitle: AppLocalizations.of(context).cashOnPickupSubtitle,
                selected: _payment == _PaymentMethod.cash,
                onTap: () => setState(() => _payment = _PaymentMethod.cash),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text('Special Instructions (Pasalubong / Packing)', style: AppTextStyles.titleMd),
            const SizedBox(height: 8),
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                hintText: 'Optional note: add extra paper bag for pasalubong gift...',
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLength: InputLimits.note,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              minLines: 1,
              maxLines: 3,
              validator: (v) => ValidationUtils.validateText(v, fieldName: 'Special instructions'),
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order Summary (${cart.itemCount} items)', style: AppTextStyles.titleMd),
                  const SizedBox(height: 10),
                  for (final line in cart.lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              '${line.quantity}x ${line.product.name}',
                              style: AppTextStyles.bodyMd,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text('₱${line.lineTotal.toStringAsFixed(0)}', style: AppTextStyles.bodyMd),
                        ],
                      ),
                    ),
                  const Divider(height: 20),
                  _SummaryLine('Subtotal', '₱${cart.subtotal.toStringAsFixed(0)}'),
                  if (cart.voucherDiscount + cart.loyaltyDiscount > 0)
                    _SummaryLine(
                      'Discounts applied',
                      '-₱${(cart.voucherDiscount + cart.loyaltyDiscount).toStringAsFixed(0)}',
                      color: AppColors.success,
                    ),
                  _SummaryLine(
                    'Fulfillment Fee',
                    _fulfillment == _FulfillmentMethod.pickup ? '₱0.00 (Store Pickup)' : '₱${deliveryFee.toStringAsFixed(2)}',
                    color: AppColors.success,
                  ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total Payable', style: AppTextStyles.headlineSm),
                      Text(
                        '₱${total.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('TOTAL PAYABLE', style: AppTextStyles.bodySm),
                      Text(
                        '₱${total.toStringAsFixed(0)}',
                        style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PrimaryButton(
                    label: _payment == _PaymentMethod.online ? 'Place Order & Pay' : 'Place Order',
                    icon: Icons.arrow_forward_rounded,
                    loading: _placingOrder,
                    onPressed: cart.lines.isEmpty ? null : _placeOrder,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryLine(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.bodyMd),
          Text(value, style: AppTextStyles.bodyMd.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailingLabel;
  final bool selected;

  /// Null disables the card (e.g. the selected branch doesn't offer this
  /// fulfillment method).
  final VoidCallback? onTap;

  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailingLabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected && !disabled ? AppColors.primaryContainer.withValues(alpha: 0.3) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected && !disabled ? AppColors.primary : AppColors.border,
              width: selected && !disabled ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: AppColors.darkBrown),
                  const Spacer(),
                  Text(
                    trailingLabel,
                    style: AppTextStyles.labelMd.copyWith(
                      color: trailingLabel == 'FREE' ? AppColors.success : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(title, style: AppTextStyles.labelLg),
              Text(subtitle, style: AppTextStyles.bodySm),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _PaymentTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 1.6 : 1),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Icon(icon, color: AppColors.darkBrown),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTextStyles.labelLg),
                    Text(subtitle, style: AppTextStyles.bodySm),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Order review of the delivery pin: the map with the pin (and the branch)
/// so the customer can check it, or a clear "pin it first" message. Warns —
/// without blocking — when the pin is unusually far from the branch.
class _DeliveryPinReview extends StatelessWidget {
  final double? latitude;
  final double? longitude;
  final String? branchName;
  final double? branchLatitude;
  final double? branchLongitude;
  final VoidCallback onPin;

  const _DeliveryPinReview({
    required this.latitude,
    required this.longitude,
    required this.onPin,
    this.branchName,
    this.branchLatitude,
    this.branchLongitude,
  });

  @override
  Widget build(BuildContext context) {
    final pin = DeliveryMap.point(latitude, longitude);
    final far = GeoUtils.farFromBranchWarning(
      lat: latitude,
      lng: longitude,
      branchLat: branchLatitude,
      branchLng: branchLongitude,
      branchName: branchName ?? 'the branch',
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: pin == null ? AppColors.warning : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(pin == null ? Icons.wrong_location_outlined : Icons.location_on_rounded,
                  color: pin == null ? AppColors.warning : AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(pin == null ? 'Pin your delivery location' : 'Delivery pin', style: AppTextStyles.labelLg),
              ),
              TextButton(onPressed: onPin, child: Text(pin == null ? 'Pin on map' : 'Move pin')),
            ],
          ),
          if (pin == null)
            Text('Required for delivery: the rider goes exactly where you pin.', style: AppTextStyles.bodySm)
          else ...[
            const SizedBox(height: 6),
            DeliveryMap(
              key: const ValueKey('checkout-pin-map'),
              pin: pin,
              pinLabel: 'Deliver here',
              branch: DeliveryMap.point(branchLatitude, branchLongitude),
              branchLabel: branchName ?? '—',
              height: 170,
            ),
          ],
          if (far != null) ...[
            const SizedBox(height: 6),
            Text(far, style: AppTextStyles.bodySm.copyWith(color: AppColors.warning)),
          ],
        ],
      ),
    );
  }
}

/// Inline "add a contact number" step for pickup checkout. Owns its text
/// controller so it is disposed with the dialog, not mid-animation.
class _ContactPhoneDialog extends StatefulWidget {
  final Future<void> Function(String normalizedPhone) onSave;

  const _ContactPhoneDialog({required this.onSave});

  @override
  State<_ContactPhoneDialog> createState() => _ContactPhoneDialogState();
}

class _ContactPhoneDialogState extends State<_ContactPhoneDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(ValidationUtils.normalizePhone(_controller.text));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = AppErrors.from(e, scope: ErrorScope.profile).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a contact number'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The branch uses this to reach you about your pickup order.'),
            const SizedBox(height: 12),
            TextFormField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: InputRules.phone(),
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                hintText: '09XX XXX XXXX',
              ),
              validator: (v) => ValidationUtils.validatePhone(v),
              onFieldSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving...' : 'Save and continue'),
        ),
      ],
    );
  }
}
