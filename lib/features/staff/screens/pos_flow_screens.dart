import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../app/routes.dart';
import '../../../core/services/staff_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/app_error.dart';
import '../../../core/utils/format_utils.dart';
import '../../../core/utils/validation_utils.dart';
import '../../../core/utils/input_rules.dart';
import '../../../core/utils/form_utils.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../data/models/staff_models.dart';
import '../../../data/repositories/staff_repository.dart';
import '../widgets/pos_offline_widgets.dart';

/// Everything the checkout screens share. [idempotencyKey] is created once per
/// checkout so that retrying after a dropped connection can never ring the
/// same sale up twice (the database returns the original sale instead).
class PosCheckout {
  final Map<String, int> cart; // variantId -> quantity
  final String? customerUid;
  final String? customerName;
  final String idempotencyKey;
  final String? method; // cash | gcash | card

  const PosCheckout({
    required this.cart,
    required this.idempotencyKey,
    this.customerUid,
    this.customerName,
    this.method,
  });

  PosCheckout withMethod(String m) => PosCheckout(
        cart: cart,
        idempotencyKey: idempotencyKey,
        customerUid: customerUid,
        customerName: customerName,
        method: m,
      );

  /// Display total using the prices the register currently shows. The
  /// database recomputes the real total from the catalog when the sale is
  /// recorded.
  double get total {
    double sum = 0;
    cart.forEach((variantId, qty) {
      final item = StaffStore.instance.itemByVariant(variantId);
      if (item != null) sum += item.price * qty;
    });
    return sum;
  }
}

String _newKey() {
  final r = Random.secure();
  final bytes = List<int>.generate(12, (_) => r.nextInt(256));
  return 'pos-${DateTime.now().microsecondsSinceEpoch}-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Records the sale in the database and refreshes live data.
Future<PosSaleResult> _submitSale(
  PosCheckout c, {
  String? reference,
  double? cashReceived,
}) async {
  final store = StaffStore.instance;
  final branchId = store.activeBranchId;
  if (branchId == null) {
    throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
  }
  final result = await StaffRepository.instance.createPosSale(
    branchId: branchId,
    quantitiesByVariant: c.cart,
    paymentMethod: c.method!,
    idempotencyKey: c.idempotencyKey,
    paymentReference: reference,
    cashReceived: cashReceived,
    customerUid: c.customerUid,
  );
  unawaited(store.refreshLive());
  return result;
}

/// The sale could not reach the server: offer to keep it on the device
/// ([PosSaleQueue]). Returns true when it was saved (the caller then leaves
/// the checkout). Only offered for a connectivity failure — a sale the server
/// answered and refused is never queued.
Future<bool> _saveOfflineIfDisconnected(
  BuildContext context,
  Object error,
  PosCheckout c, {
  String? reference,
  double? cashReceived,
}) async {
  final branchId = StaffStore.instance.activeBranchId;
  if (branchId == null || c.method == null || !AppErrors.from(error).isConnectivity) return false;
  final saved = await offerOfflineSave(
    context,
    branchId: branchId,
    cart: c.cart,
    paymentMethod: c.method!,
    idempotencyKey: c.idempotencyKey,
    displayedTotal: c.total,
    reference: reference,
    cashReceived: cashReceived,
    customerUid: c.customerUid,
  );
  if (saved && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sale saved on this device. It will be sent when the connection returns.')),
    );
    Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (route) => false);
  }
  return saved;
}

/// POS Cart — review the sale and optionally attach a loyalty customer.
class PosCartScreen extends StatefulWidget {
  final Map<String, int> initialCart;

  const PosCartScreen({super.key, required this.initialCart});

  @override
  State<PosCartScreen> createState() => _PosCartScreenState();
}

class _PosCartScreenState extends State<PosCartScreen> {
  late final Map<String, int> _cart = Map.from(widget.initialCart);
  final String _key = _newKey();
  CustomerMatch? _customer;

  PosCheckout get _checkout => PosCheckout(
        cart: Map.from(_cart),
        idempotencyKey: _key,
        customerUid: _customer?.uid,
        customerName: _customer?.name,
      );

  void _change(String variantId, int delta) {
    final item = StaffStore.instance.itemByVariant(variantId);
    final current = _cart[variantId] ?? 0;
    final next = current + delta;
    if (next <= 0) {
      setState(() => _cart.remove(variantId));
      if (_cart.isEmpty) Navigator.of(context).pop();
      return;
    }
    if (item != null && next > item.quantity) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Only ${item.quantity} in stock.')));
      return;
    }
    setState(() => _cart[variantId] = next);
  }

  Future<void> _lookupCustomer() async {
    final picked = await showDialog<CustomerMatch>(
      context: context,
      builder: (_) => const _CustomerLookupDialog(),
    );
    if (picked != null && mounted) setState(() => _customer = picked);
  }

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final checkout = _checkout;
        final total = checkout.total;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: AppBar(title: const Text('POS Checkout')),
          body: Column(
            children: [
              if (_customer != null)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  color: AppColors.successBg,
                  child: Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: AppColors.success),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('CUSTOMER: ${_customer!.name}', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
                            Text('${_customer!.points} points • more points are added after checkout.', style: AppTextStyles.bodySm),
                          ],
                        ),
                      ),
                      TextButton(onPressed: () => setState(() => _customer = null), child: const Text('Remove')),
                    ],
                  ),
                )
              else
                InkWell(
                  onTap: _lookupCustomer,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    color: AppColors.primaryContainer.withValues(alpha: 0.3),
                    child: Row(
                      children: [
                        const Icon(Icons.contactless_rounded, color: AppColors.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Find loyalty customer (card no., phone or email)',
                              style: AppTextStyles.labelLg.copyWith(color: AppColors.primaryDark)),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Text('Order Summary', style: AppTextStyles.titleMd),
                    const SizedBox(height: 10),
                    for (final e in _cart.entries) _line(store, e.key, e.value),
                    const Divider(),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Subtotal', style: AppTextStyles.bodyMd),
                        Text(peso(total), style: AppTextStyles.bodyMd),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -4))],
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('TOTAL PAYABLE', style: AppTextStyles.bodySm),
                            Text(peso(total), style: AppTextStyles.headlineSm.copyWith(color: AppColors.primary)),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 160,
                        child: PrimaryButton(
                          label: 'Next: Payment',
                          onPressed: _cart.isEmpty
                              ? null
                              : () async {
                                  final done = await Navigator.of(context)
                                      .pushNamed(AppRoutes.staffPosPayment, arguments: _checkout);
                                  if (done == true && context.mounted) Navigator.of(context).pop(true);
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _line(StaffStore store, String variantId, int qty) {
    final item = store.itemByVariant(variantId);
    if (item == null) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(item.displayName, style: AppTextStyles.labelLg),
      subtitle: Text('${peso(item.price)} each'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: 'One less', icon: const Icon(Icons.remove_circle_outline_rounded), onPressed: () => _change(variantId, -1)),
          Text('$qty', style: AppTextStyles.labelLg),
          IconButton(tooltip: 'One more', icon: const Icon(Icons.add_circle_outline_rounded), onPressed: () => _change(variantId, 1)),
          SizedBox(width: 72, child: Text(peso(item.price * qty), textAlign: TextAlign.right, style: AppTextStyles.labelLg)),
        ],
      ),
    );
  }
}

/// Looks a loyalty customer up by RFID card number, phone or email. The
/// database only returns an exact match, so this cannot be used to browse
/// customers.
class _CustomerLookupDialog extends StatefulWidget {
  const _CustomerLookupDialog();

  @override
  State<_CustomerLookupDialog> createState() => _CustomerLookupDialogState();
}

class _CustomerLookupDialogState extends State<_CustomerLookupDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _message;
  List<CustomerMatch> _results = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.length < 4) {
      setState(() => _message = 'Enter at least 4 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = await StaffRepository.instance.lookupCustomer(q);
      if (!mounted) return;
      // A card tapped on the reader matches exactly one customer: attach at once.
      if (r.length == 1 && looksLikeCardUid(q)) {
        Navigator.pop(context, r.first);
        return;
      }
      setState(() {
        _results = r;
        _busy = false;
        _message = r.isEmpty ? 'No loyalty customer found.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = AppErrors.from(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Loyalty customer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: InputLimits.email,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              counterText: '',
              errorText: _results.isEmpty ? _message : null,
              errorMaxLines: 3,
              labelText: 'Tap card, or type phone / email / GK- label',
              suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.search_rounded), onPressed: _busy ? null : _search),
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: CircularProgressIndicator()),
          for (final c in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline_rounded),
              title: Text(c.name),
              subtitle: Text('${c.points} points'),
              trailing: IconButton(
                tooltip: 'Link RFID card',
                icon: const Icon(Icons.contactless_rounded),
                onPressed: () => showDialog<void>(context: context, builder: (_) => _LinkCardDialog(customer: c)),
              ),
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

/// True when [q] looks like what a card reader sends (8–20 hex digits, with or
/// without separators). Same rule as the server's `_normalize_card_uid`.
bool looksLikeCardUid(String q) =>
    RegExp(r'^[0-9A-F]{8,20}$').hasMatch(q.toUpperCase().replaceAll(RegExp(r'[\s:\-.]'), ''));

/// Links a new RFID card to [customer], or replaces their lost / damaged card.
/// A keyboard-mode reader (Arduino Pro Micro, see hardware/rfid-reader/) types
/// the UID and presses Enter into the focused field.
class _LinkCardDialog extends StatefulWidget {
  final CustomerMatch customer;
  const _LinkCardDialog({required this.customer});

  @override
  State<_LinkCardDialog> createState() => _LinkCardDialogState();
}

class _LinkCardDialogState extends State<_LinkCardDialog> {
  final _card = TextEditingController();
  final _reason = TextEditingController();
  final String _key = _newKey();
  bool _replace = false;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _card.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uid = _card.text.trim();
    if (!looksLikeCardUid(uid)) {
      setState(() => _message = 'Tap the card on the reader.');
      return;
    }
    final reasonError = _replace
        ? ValidationUtils.validateReason(_reason.text, minLength: 3, maxLength: 200)
        : null;
    if (reasonError != null) {
      setState(() => _message = reasonError);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final repo = StaffRepository.instance;
      final label = _replace
          ? await repo.replaceLoyaltyCard(
              customerUid: widget.customer.uid, newCardUid: uid, reason: _reason.text.trim(), idempotencyKey: _key)
          : await repo.registerLoyaltyCard(cardUid: uid, customerUid: widget.customer.uid, idempotencyKey: _key);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Card $label linked to ${widget.customer.name}.')));
    } catch (e) {
      if (!mounted) return;
      final msg = AppErrors.from(e).message;
      setState(() {
        _busy = false;
        _message = msg;
        // The server says the customer already has a card: offer the replace flow.
        if (msg.contains('Replace card')) _replace = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_replace ? 'Replace card' : 'Link RFID card'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Customer: ${widget.customer.name}', style: AppTextStyles.labelLg),
          const SizedBox(height: 8),
          TextField(
            controller: _card,
            autofocus: true,
            enabled: !_busy,
            maxLength: 32,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f:\-.\s]'))],
            onSubmitted: (_) {
              if (!_replace) _save();
            },
            decoration: const InputDecoration(
              labelText: 'Tap the new card',
              prefixIcon: Icon(Icons.contactless_rounded),
              counterText: '',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _replace,
            onChanged: _busy ? null : (v) => setState(() => _replace = v ?? false),
            title: const Text('Replaces a lost or damaged card'),
            subtitle: const Text('The old card stops working. Points are kept.'),
          ),
          if (_replace)
            TextField(
              controller: _reason,
              enabled: !_busy,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Reason (e.g. lost)'),
            ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: CircularProgressIndicator()),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message!, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _busy ? null : _save, child: Text(_replace ? 'Replace' : 'Link card')),
      ],
    );
  }
}

/// Payment selection screen for Staff.
class PosPaymentScreen extends StatelessWidget {
  final PosCheckout checkout;
  const PosPaymentScreen({super.key, required this.checkout});

  Future<void> _go(BuildContext context, String route, String method) async {
    final done = await Navigator.of(context).pushNamed(route, arguments: checkout.withMethod(method));
    if (done == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Select Payment Method')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Text('Total Amount to Collect', style: AppTextStyles.bodyMd),
          Text(peso(checkout.total), style: AppTextStyles.headlineLg.copyWith(color: AppColors.primary)),
          const SizedBox(height: AppSpacing.lg),
          _PaymentOption(
            icon: Icons.money_rounded,
            title: 'Cash',
            subtitle: 'Collect physical cash from customer',
            onTap: () => _go(context, AppRoutes.staffPosCashInput, 'cash'),
          ),
          const SizedBox(height: 12),
          _PaymentOption(
            icon: Icons.account_balance_wallet_rounded,
            title: 'GCash',
            subtitle: 'Customer pays in GCash; enter the reference number',
            onTap: () => _go(context, AppRoutes.staffPosProcessing, 'gcash'),
          ),
          const SizedBox(height: 12),
          _PaymentOption(
            icon: Icons.credit_card_rounded,
            title: 'Card (Visa/Mastercard)',
            subtitle: 'Charge on the card terminal; enter the approval code',
            onTap: () => _go(context, AppRoutes.staffPosProcessing, 'card'),
          ),
        ],
      ),
    );
  }
}

class _PaymentOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PaymentOption({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.surfaceContainerLow, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.labelLg),
                  Text(subtitle, style: AppTextStyles.bodySm),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Cash: enter the amount handed over; the sale is recorded when confirmed.
class PosCashInputScreen extends StatefulWidget {
  final PosCheckout checkout;

  const PosCashInputScreen({super.key, required this.checkout});

  @override
  State<PosCashInputScreen> createState() => _PosCashInputScreenState();
}

class _PosCashInputScreenState extends State<PosCashInputScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _controller = TextEditingController();
  double _received = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _received = double.tryParse(_controller.text) ?? 0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (_saving || !FormUtils.validateAndFocus(_formKey)) return;
    setState(() => _saving = true);
    try {
      final sale = await _submitSale(widget.checkout, cashReceived: _received);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.staffPosReceipt, arguments: sale);
    } catch (e) {
      if (!mounted) return;
      if (await _saveOfflineIfDisconnected(context, e, widget.checkout, cashReceived: _received)) return;
      if (!mounted) return;
      setState(() => _saving = false);
      AppErrors.showSnack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount = widget.checkout.total;
    final double change = _received > amount ? _received - amount : 0;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Cash Payment')),
      body: Form(
        key: _formKey,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Total to Pay', style: AppTextStyles.bodyMd),
              Text(peso(amount), style: AppTextStyles.headlineLg.copyWith(color: AppColors.primary)),
              const SizedBox(height: 24),
              TextFormField(
                controller: _controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: AppTextStyles.headlineMd,
                autofocus: true,
                inputFormatters: InputRules.decimal(),
                // At least the total, at most ₱1,000,000, 2 decimals.
                validator: (v) => ValidationUtils.validateNumber(
                  v,
                  fieldName: 'Amount received',
                  min: amount,
                  max: 1000000,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount Received',
                  prefixText: '₱ ',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(color: AppColors.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Change Due', style: AppTextStyles.labelLg),
                    Text(peso(change), style: AppTextStyles.headlineSm.copyWith(color: AppColors.success)),
                  ],
                ),
              ),
              const Spacer(),
              PrimaryButton(label: 'Complete Payment', loading: _saving, onPressed: _complete),
            ],
          ),
        ),
      ),
    );
  }
}

/// GCash / card: the customer pays on their phone or on the card terminal and
/// staff enter the reference the payment app / terminal shows. The sale is
/// recorded only when staff confirm the payment was received.
class PosProcessingScreen extends StatefulWidget {
  final PosCheckout checkout;

  const PosProcessingScreen({super.key, required this.checkout});

  @override
  State<PosProcessingScreen> createState() => _PosProcessingScreenState();
}

class _PosProcessingScreenState extends State<PosProcessingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reference = TextEditingController();
  bool _saving = false;

  bool get _isGcash => widget.checkout.method == 'gcash';

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving || !FormUtils.validateAndFocus(_formKey)) return;
    setState(() => _saving = true);
    try {
      final sale = await _submitSale(widget.checkout, reference: _reference.text.trim());
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.staffPosReceipt, arguments: sale);
    } catch (e) {
      if (!mounted) return;
      if (await _saveOfflineIfDisconnected(context, e, widget.checkout, reference: _reference.text.trim())) return;
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.staffPosFailed, arguments: AppErrors.from(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text(_isGcash ? 'GCash Payment' : 'Card Payment')),
      body: Form(
        key: _formKey,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Amount to collect', style: AppTextStyles.bodyMd),
              Text(peso(widget.checkout.total), style: AppTextStyles.headlineLg.copyWith(color: AppColors.primary)),
              const SizedBox(height: 16),
              Text(
                _isGcash
                    ? 'Ask the customer to pay this amount in GCash, then enter the reference number from their payment confirmation.'
                    : 'Charge this amount on the card terminal, then enter the approval / reference code printed on the terminal slip.',
                style: AppTextStyles.bodyMd,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _reference,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                keyboardType: _isGcash ? TextInputType.number : TextInputType.text,
                maxLength: 40,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]'))],
                decoration: InputDecoration(
                  labelText: _isGcash ? 'GCash reference number' : 'Approval / reference code',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.length < 4) return 'Enter the reference (at least 4 characters)';
                  if (_isGcash && !RegExp(r'^\d{4,40}$').hasMatch(t)) return 'A GCash reference number has digits only';
                  return null;
                },
              ),
              const Spacer(),
              PrimaryButton(label: 'Confirm Payment Received', loading: _saving, onPressed: _confirm),
            ],
          ),
        ),
      ),
    );
  }
}

/// Receipt for a recorded sale, loaded from the database.
class PosReceiptScreen extends StatelessWidget {
  final PosSaleResult sale;

  const PosReceiptScreen({super.key, required this.sale});

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Receipt'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: FutureBuilder<StaffOrder?>(
          future: StaffRepository.instance.fetchOrder(store.activeBranchId, sale.orderId),
          builder: (context, snap) {
            final order = snap.data;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 64),
                const SizedBox(height: 8),
                Text('Payment Successful', textAlign: TextAlign.center, style: AppTextStyles.headlineSm),
                Text(sale.orderId, textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
                const SizedBox(height: AppSpacing.lg),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: [
                      if (snap.connectionState == ConnectionState.waiting)
                        const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
                      else if (order != null) ...[
                        for (final i in order.items)
                          _row('${i.quantity} × ${i.productName}${i.variantLabel.isEmpty ? '' : ' • ${i.variantLabel}'}', peso(i.total)),
                        const Divider(height: 24),
                      ],
                      _row('Total', peso(sale.total), bold: true),
                      if (order != null) _row('Paid with', order.paymentMethod),
                      if (order?.cashReceived != null) _row('Cash received', peso(order!.cashReceived!)),
                      if (sale.change > 0) _row('Change', peso(sale.change)),
                      if (sale.pointsEarned > 0) _row('Loyalty points earned', '+${sale.pointsEarned}'),
                      if (sale.alreadyRecorded)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('This sale had already been recorded; it was not charged twice.', style: AppTextStyles.bodySm),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                  label: 'New Sale',
                  icon: Icons.add_shopping_cart_rounded,
                  onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (route) => false),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label, style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd)),
            const SizedBox(width: 12),
            Text(value, style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd),
          ],
        ),
      );
}

/// Shown when the sale could not be recorded. Nothing was charged in the
/// system; the message explains why (for example, stock changed).
class PosFailedScreen extends StatelessWidget {
  const PosFailedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final message = ModalRoute.of(context)?.settings.arguments as String? ??
        'The sale could not be recorded. Please try again.';
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Payment Failed'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 72),
              const SizedBox(height: 16),
              Text('Sale not recorded', style: AppTextStyles.headlineSm),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: AppTextStyles.bodyMd),
              const SizedBox(height: 32),
              PrimaryButton(label: 'Try Again', onPressed: () => Navigator.of(context).pop()),
              TextButton(
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (route) => false),
                child: const Text('Cancel Transaction'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
