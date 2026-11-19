import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../app/routes.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/nfc_card_reader.dart';
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
import '../pos_sale_attempt.dart';
import '../widgets/pos_offline_widgets.dart';

/// Everything the checkout screens share. [attempt] holds the checkout's
/// idempotency key: retrying the same sale after a dropped connection can
/// never ring it up twice (the database returns the original sale instead),
/// and a changed sale after a refused attempt gets a new key (see
/// [PosSaleAttempt]).
///
/// [quote] is the database's own total (`staff_pos_quote`) for a sale with a
/// loyalty customer; with [redeemPoints] it includes the points discount,
/// computed by the same rule as an app order.
class PosCheckout {
  final Map<String, int> cart; // variantId -> quantity
  final String? customerUid;
  final String? customerName;
  final PosSaleAttempt attempt;
  final String? method; // cash | gcash | card
  final bool redeemPoints;
  final bool customerConfirmed;
  final String? loyaltyPin;
  final PosQuote? quote;

  const PosCheckout({
    required this.cart,
    required this.attempt,
    this.customerUid,
    this.customerName,
    this.method,
    this.redeemPoints = false,
    this.customerConfirmed = false,
    this.loyaltyPin,
    this.quote,
  });

  PosCheckout withMethod(String m) => PosCheckout(
        cart: cart,
        attempt: attempt,
        customerUid: customerUid,
        customerName: customerName,
        method: m,
        redeemPoints: redeemPoints,
        customerConfirmed: customerConfirmed,
        loyaltyPin: loyaltyPin,
        quote: quote,
      );

  /// The amount to collect: the database's quote when there is one,
  /// otherwise the prices the register currently shows. Either way the
  /// database recomputes the real total when the sale is recorded.
  ///
  /// Summed in whole centavos so the total is exact: adding doubles gives
  /// ₱45.10 + ₱45.20 = 90.30000000000001, and the cash screen would then
  /// refuse an exact ₱90.30 payment.
  double get total {
    final q = quote;
    if (q != null) return q.total;
    var cents = 0;
    cart.forEach((variantId, qty) {
      final item = StaffStore.instance.itemByVariant(variantId);
      if (item != null) cents += toCents(item.price) * qty;
    });
    return cents / 100;
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
  // Same request -> same key (safe retry); a changed request after a refused
  // attempt -> new key.
  final key = c.attempt.keyFor(PosSaleAttempt.fingerprintOf(
    branchId: branchId,
    cart: c.cart,
    method: c.method!,
    customerUid: c.customerUid,
    reference: reference,
    redeemPoints: c.redeemPoints,
  ));
  final PosSaleResult result;
  try {
    result = await StaffRepository.instance.createPosSale(
      branchId: branchId,
      quantitiesByVariant: c.cart,
      paymentMethod: c.method!,
      idempotencyKey: key,
      paymentReference: reference,
      cashReceived: cashReceived,
      customerUid: c.customerUid,
      redeemPoints: c.redeemPoints,
      loyaltyPin: c.loyaltyPin,
      customerConfirmed: c.customerConfirmed,
    );
  } catch (e) {
    final mapped = AppErrors.from(e);
    c.attempt.markFailed(outcomeUnknown: mapped.isConnectivity);
    if (c.redeemPoints && mapped.isConnectivity) {
      // Points are checked against the live balance, so they cannot be
      // queued on the device. Retrying uses the same key (never twice).
      throw AppError(
        mapped.kind,
        'No connection. Using points needs a connection: try again, or go back, turn off '
        '"Use points" and save the sale on this device.',
      );
    }
    rethrow;
  }
  unawaited(store.refreshLive());
  return result;
}

/// The sale could not reach the server: offer to keep it on the device
/// ([PosSaleQueue]). Returns true when it was saved (the caller then leaves
/// the checkout). Only offered for a connectivity failure — a sale the server
/// answered and refused is never queued — and never for a sale that redeems
/// points (the balance must be checked live).
Future<bool> _saveOfflineIfDisconnected(
  BuildContext context,
  Object error,
  PosCheckout c, {
  String? reference,
  double? cashReceived,
}) async {
  final branchId = StaffStore.instance.activeBranchId;
  if (branchId == null || c.method == null || c.redeemPoints || !AppErrors.from(error).isConnectivity) return false;
  final saved = await offerOfflineSave(
    context,
    branchId: branchId,
    cart: c.cart,
    paymentMethod: c.method!,
    // The key the failed request was sent with: if the server did record
    // it, sending the queued copy later returns that sale instead of a second.
    idempotencyKey: c.attempt.currentKey,
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

/// POS Cart — review the sale and optionally attach a loyalty customer
/// (tap their card on this phone, the counter reader, or type phone / e-mail).
/// With a customer attached the totals come from the database, and points can
/// be used by the same rule as an app order.
class PosCartScreen extends StatefulWidget {
  final Map<String, int> initialCart;

  const PosCartScreen({super.key, required this.initialCart});

  @override
  State<PosCartScreen> createState() => _PosCartScreenState();
}

class _PosCartScreenState extends State<PosCartScreen> {
  late final Map<String, int> _cart = Map.from(widget.initialCart);
  final PosSaleAttempt _attempt = PosSaleAttempt();
  final TextEditingController _pin = TextEditingController();
  CustomerMatch? _customer;
  bool _confirmed = false;
  bool _redeem = false;
  PosQuote? _quote;
  bool _quoteLoading = false;
  Object? _quoteError;
  int _quoteSeq = 0;

  static final RegExp _pinRule = RegExp(r'^\d{4,6}$');

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  bool get _online => ConnectivityService.instance.isOnline;

  PosCheckout get _checkout => PosCheckout(
        cart: Map.from(_cart),
        attempt: _attempt,
        customerUid: _customer?.uid,
        customerName: _customer?.name,
        redeemPoints: _redeem,
        customerConfirmed: _confirmed,
        loyaltyPin: _redeem && (_quote?.pinRequired ?? false) ? _pin.text : null,
        // Only a quote for exactly this cart / customer / choice is used.
        quote: _quoteLoading || _quoteError != null ? null : _quote,
      );

  /// Asks the database for the totals of the current cart and choice.
  Future<void> _refreshQuote() async {
    final customer = _customer;
    final branchId = StaffStore.instance.activeBranchId;
    final seq = ++_quoteSeq;
    if (customer == null || branchId == null || _cart.isEmpty || !_online) {
      setState(() {
        _quote = null;
        _quoteError = null;
        _quoteLoading = false;
        if (!_online) _redeem = false;
      });
      return;
    }
    setState(() {
      _quoteLoading = true;
      _quoteError = null;
    });
    try {
      final q = await StaffRepository.instance.posQuote(
        branchId: branchId,
        quantitiesByVariant: Map.from(_cart),
        customerUid: customer.uid,
        redeemPoints: _redeem,
      );
      if (!mounted || seq != _quoteSeq) return;
      setState(() {
        _quote = q;
        _quoteLoading = false;
        if (_redeem && !q.canRedeem) _redeem = false;
      });
    } catch (e) {
      if (!mounted || seq != _quoteSeq) return;
      setState(() {
        _quoteLoading = false;
        _quoteError = e;
      });
    }
  }

  void _change(String variantId, int delta) {
    final item = StaffStore.instance.itemByVariant(variantId);
    final current = _cart[variantId] ?? 0;
    final next = current + delta;
    if (next <= 0) {
      setState(() => _cart.remove(variantId));
      if (_cart.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      unawaited(_refreshQuote());
      return;
    }
    if (item != null && next > item.quantity) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Only ${item.quantity} in stock.')));
      return;
    }
    setState(() => _cart[variantId] = next);
    unawaited(_refreshQuote());
  }

  Future<void> _lookupCustomer() async {
    final picked = await showDialog<CustomerMatch>(
      context: context,
      builder: (_) => const _CustomerLookupDialog(),
    );
    if (picked != null && mounted) {
      setState(() {
        _customer = picked;
        _confirmed = false;
        _redeem = false;
        _pin.clear();
      });
      unawaited(_refreshQuote());
    }
  }

  void _removeCustomer() {
    setState(() {
      _customer = null;
      _confirmed = false;
      _redeem = false;
      _pin.clear();
    });
    unawaited(_refreshQuote());
  }

  /// Why "Next" is not available yet, or null.
  String? _blocker() {
    if (_cart.isEmpty) return 'The cart is empty.';
    if (_customer != null && _quoteLoading) return 'Getting the totals…';
    if (_redeem) {
      if (_quoteError != null || _quote == null) return 'The points total could not be loaded. Retry or turn off "Use points".';
      if (!_confirmed) return 'Confirm the customer\'s name to use points.';
      if (_quote!.pinRequired && !_pinRule.hasMatch(_pin.text)) return 'Enter the customer\'s loyalty PIN.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final store = StaffStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([store, ConnectivityService.instance]),
      builder: (context, _) {
        final checkout = _checkout;
        final total = checkout.total;
        final blocker = _blocker();
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: AppBar(title: const Text('POS Checkout')),
          body: Column(
            children: [
              if (_customer != null)
                _customerPanel(_customer!)
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
                          child: Text('Find loyalty customer (tap card)',
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
                    ..._totals(checkout),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (blocker != null && _customer != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(blocker, style: AppTextStyles.bodySm.copyWith(color: AppColors.textSecondary)),
                        ),
                      Row(
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
                              onPressed: blocker != null
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

  /// Name check (the card is only a lookup key), points and the PIN.
  Widget _customerPanel(CustomerMatch customer) {
    final q = _quote;
    final canRedeem = _online && q != null && q.canRedeem;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
      color: AppColors.successBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: AppColors.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CUSTOMER: ${customer.name}', style: AppTextStyles.labelLg.copyWith(color: AppColors.success)),
                    Text('${q?.pointsBalance ?? customer.points} points available', style: AppTextStyles.bodySm),
                  ],
                ),
              ),
              TextButton(onPressed: _removeCustomer, child: const Text('Remove')),
            ],
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: Text('Customer confirmed this is their name', style: AppTextStyles.bodyMd),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _redeem,
            onChanged: canRedeem
                ? (v) {
                    setState(() => _redeem = v);
                    unawaited(_refreshQuote());
                  }
                : null,
            title: Text('Use points', style: AppTextStyles.labelLg),
            subtitle: Text(
              !_online
                  ? 'Needs a connection. Points are still earned on an offline sale.'
                  : q == null
                      ? (_quoteLoading ? 'Checking points…' : 'Points could not be checked.')
                      : !q.redeemConfigured
                          ? 'Point redemption is not set up by the owner.'
                          : q.maxPointsRedeemable <= 0
                              ? 'No points can be used on this sale.'
                              : 'Up to ${q.maxPointsRedeemable} points (−${peso(q.maxDiscount)}) on this sale',
              style: AppTextStyles.bodySm,
            ),
          ),
          if (_redeem && (q?.pinRequired ?? false))
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Customer enters their loyalty PIN',
                prefixIcon: Icon(Icons.lock_rounded),
                counterText: '',
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _totals(PosCheckout checkout) {
    Widget row(String label, String value, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd),
              Text(value, style: (bold ? AppTextStyles.labelLg : AppTextStyles.bodyMd).copyWith(color: color)),
            ],
          ),
        );
    if (_customer != null && _quoteLoading) {
      return [const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))];
    }
    if (_customer != null && _quoteError != null) {
      return [
        Text(AppErrors.from(_quoteError!).message, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _refreshQuote, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
        ),
        row('Subtotal (register prices)', peso(checkout.total)),
      ];
    }
    final q = checkout.quote;
    if (q == null) return [row('Subtotal', peso(checkout.total))];
    return [
      row('Subtotal', peso(q.subtotal)),
      if (q.pointsUsed > 0) row('Points used (${q.pointsUsed} pts)', '−${peso(q.loyaltyDiscount)}', color: AppColors.success),
      row('Total payable', peso(q.total), bold: true),
      if (q.pointsToEarn > 0) row('Points to earn', '+${q.pointsToEarn}'),
    ];
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

/// Finds a loyalty customer by their card.
///
/// The first time on a phone, staff are asked to allow the app to use this
/// phone's NFC ("Allow NFC"); the choice is saved on the phone and can be
/// changed in Settings > Permissions. When NFC is off in the phone settings, a
/// "Turn on NFC" button opens them. Once allowed and on, opening this dialog
/// turns the reader on straight away: the customer holds the card against the
/// back of THIS phone. The counter reader (keyboard mode) also works here,
/// caught without a text box. After an unknown / blocked card the reader keeps
/// listening, and it is switched on again when the app comes back to the front
/// (Android stops it while the app is in the background).
///
/// A text box (counter reader, GK- label, phone or e-mail) is shown only when
/// this phone cannot read cards, or when staff chose "Type instead". The
/// database only returns an exact match, so this cannot be used to browse
/// customers.
class _CustomerLookupDialog extends StatefulWidget {
  const _CustomerLookupDialog();

  @override
  State<_CustomerLookupDialog> createState() => _CustomerLookupDialogState();
}

class _CustomerLookupDialogState extends State<_CustomerLookupDialog> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _keyFocus = FocusNode(debugLabel: 'counter-reader');
  bool _busy = false;
  bool _nfcWaiting = false;
  bool _disposed = false;

  /// "Type instead" chosen for this lookup.
  bool _typing = false;
  NfcSupport? _nfc;

  /// Staff's choice on this phone (null = not asked yet).
  bool? _allowed;
  String? _message;
  List<CustomerMatch> _results = const [];

  /// Bumped to stop the current listening loop.
  int _gen = 0;

  // Counter reader in keyboard mode: it types the UID and presses Enter.
  final StringBuffer _keys = StringBuffer();
  DateTime _lastKey = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _phoneCanRead => _nfc == NfcSupport.available || _nfc == NfcSupport.disabled;
  bool get _canListen => _nfc == NfcSupport.available && _allowed == true && !_typing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _keyFocus.dispose();
    unawaited(NfcCardReader.instance.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back from the NFC settings, or the screen was off: start again.
      _refresh();
    } else if (state == AppLifecycleState.paused) {
      _gen++;
      unawaited(NfcCardReader.instance.cancel());
    }
  }

  /// Reads NFC state + the staff choice, then starts the reader if it may.
  Future<void> _refresh() async {
    _gen++;
    await NfcCardReader.instance.cancel();
    final s = await NfcCardReader.instance.support();
    final allowed = await NfcCardReader.instance.allowedOnThisPhone();
    if (!mounted) return;
    setState(() {
      _nfc = s;
      _allowed = allowed;
      _nfcWaiting = false;
    });
    if (_canListen && !_busy) unawaited(_listen());
  }

  Future<void> _allow() async {
    await NfcCardReader.instance.setAllowedOnThisPhone(true);
    if (!mounted) return;
    setState(() => _message = null);
    await _refresh();
  }

  Future<void> _turnOnNfc() async {
    final opened = await NfcCardReader.instance.openNfcSettings();
    if (!opened && mounted) {
      setState(() => _message = 'Open the phone\'s Settings, turn on NFC, then come back to this screen.');
    }
  }

  /// Keeps the phone's reader on while the dialog is open.
  Future<void> _listen() async {
    final gen = ++_gen;
    bool live() => !_disposed && gen == _gen && _canListen;
    while (live() && !_busy) {
      setState(() => _nfcWaiting = true);
      String uid;
      try {
        uid = await NfcCardReader.instance.readUid(timeout: const Duration(minutes: 2));
      } on NfcReadException catch (e) {
        if (_disposed) return;
        if (!live() || e.message == NfcCardReader.cancelledMessage) {
          if (gen == _gen) setState(() => _nfcWaiting = false);
          return;
        }
        if (e.message == NfcCardReader.startFailedMessage) {
          // The phone's NFC won't start: fall back to the text box.
          setState(() {
            _nfcWaiting = false;
            _nfc = NfcSupport.unsupported;
            _message = e.message;
          });
          return;
        }
        // Timeout: just listen again. A real problem: show it, then listen again.
        if (e.message != NfcCardReader.timeoutMessage) {
          setState(() {
            _nfcWaiting = false;
            _message = e.message;
          });
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
        continue;
      }
      if (!live()) return;
      await _lookupUid(uid);
      // Card not usable: give the staff a moment to read why, then re-arm.
      if (live() && !_busy) await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
  }

  /// A card UID from the phone or the counter reader.
  Future<void> _lookupUid(String uid) async {
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _nfcWaiting = false;
      _busy = true;
      _message = null;
      _results = const [];
    });
    try {
      final r = await StaffRepository.instance.lookupCard(uid);
      if (!mounted) return;
      if (r.isActive) {
        Navigator.pop(context, r.customer);
        return;
      }
      setState(() {
        _busy = false;
        _message = r.problem;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = AppErrors.from(e).message;
      });
    }
  }

  /// Counter reader keystrokes while there is no text box.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final now = DateTime.now();
    // The reader types a whole UID within a fraction of a second.
    if (now.difference(_lastKey) > const Duration(seconds: 1)) _keys.clear();
    _lastKey = now;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final uid = _keys.toString();
      _keys.clear();
      if (looksLikeCardUid(uid) && !_busy) {
        unawaited(() async {
          _gen++;
          await NfcCardReader.instance.cancel();
          await _lookupUid(uid);
          if (!_disposed && !_busy && _canListen) unawaited(_listen());
        }());
      }
      return KeyEventResult.handled;
    }
    final c = event.character;
    if (c != null && RegExp(r'^[0-9A-Fa-f]$').hasMatch(c)) {
      _keys.write(c.toUpperCase());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
        _message = r.isEmpty
            ? (looksLikeCardUid(q) ? 'This card is not linked to any account yet.' : 'No loyalty customer found.')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = AppErrors.from(e).message;
      });
    }
  }

  Widget _bigIcon(IconData icon, {bool active = false}) => Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(color: AppColors.primaryContainer.withValues(alpha: 0.35), shape: BoxShape.circle),
        child: _busy
            ? const Padding(padding: EdgeInsets.all(30), child: CircularProgressIndicator(strokeWidth: 3))
            : Icon(icon, size: 52, color: active ? AppColors.primary : AppColors.textSecondary),
      );

  Widget _messageLine() => _message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, textAlign: TextAlign.center, style: AppTextStyles.bodySm.copyWith(color: AppColors.error)),
        );

  Widget _typeInsteadButton() => TextButton(
        onPressed: _busy
            ? null
            : () {
                _gen++;
                unawaited(NfcCardReader.instance.cancel());
                setState(() {
                  _typing = true;
                  _nfcWaiting = false;
                  _message = null;
                });
              },
        child: const Text('Type instead (phone, e-mail or GK- label)'),
      );

  /// First time on this phone (or turned off in Settings): ask to allow NFC.
  Widget _allowPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(child: _bigIcon(Icons.nfc_rounded, active: true)),
        const SizedBox(height: 16),
        Text(
          _allowed == false ? 'NFC is turned off for this app' : 'Allow this phone to read loyalty cards?',
          textAlign: TextAlign.center,
          style: AppTextStyles.titleMd,
        ),
        const SizedBox(height: 8),
        Text(
          'Melai Nuts uses this phone\'s NFC to read only the ID number of a customer\'s loyalty card '
          'when it is held against the back of the phone. Nothing else on the card is read, nothing is '
          'written to it, and the reader is on only while this screen is open. '
          'You can change this any time in Settings > Permissions.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySm,
        ),
        _messageLine(),
        const SizedBox(height: 16),
        PrimaryButton(label: 'Allow NFC', onPressed: _allow),
        _typeInsteadButton(),
      ],
    );
  }

  /// Allowed, but NFC is switched off in the phone settings.
  Widget _nfcOffPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(child: _bigIcon(Icons.nfc_rounded)),
        const SizedBox(height: 16),
        Text('NFC is off on this phone', textAlign: TextAlign.center, style: AppTextStyles.titleMd),
        const SizedBox(height: 8),
        Text(
          'Turn on NFC in the phone settings, then come back. The reader starts by itself.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySm,
        ),
        _messageLine(),
        const SizedBox(height: 16),
        PrimaryButton(label: 'Turn on NFC', onPressed: _turnOnNfc),
        _typeInsteadButton(),
      ],
    );
  }

  /// The "hold the card here" panel (allowed and on).
  Widget _tapPanel() {
    final waiting = _nfcWaiting && !_busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Center(child: _bigIcon(Icons.contactless_rounded, active: waiting)),
        const SizedBox(height: 16),
        Text(
          _busy
              ? 'Card read. Finding the customer…'
              : waiting
                  ? 'Hold the customer\'s card flat against the back of this phone'
                  : 'Starting the card reader…',
          textAlign: TextAlign.center,
          style: AppTextStyles.labelLg,
        ),
        const SizedBox(height: 6),
        Text(
          'Keep it still for a second, near the middle / camera area. '
          'The counter reader works too.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySm,
        ),
        _messageLine(),
        const SizedBox(height: 8),
        _typeInsteadButton(),
      ],
    );
  }

  /// Text box: this phone cannot read cards, or "Type instead" was chosen.
  Widget _typePanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_phoneCanRead)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'This phone cannot read cards (no NFC, or an iPhone with MIFARE Classic cards). '
              'Use the counter reader, the GK- label on the card, or the customer\'s phone / e-mail.',
              style: AppTextStyles.bodySm,
            ),
          ),
        TextField(
          controller: _controller,
          autofocus: true,
          maxLength: InputLimits.email,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            counterText: '',
            errorText: _results.isEmpty ? _message : null,
            errorMaxLines: 4,
            labelText: 'Reader tap, card no. / GK- label, phone or email',
            suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.search_rounded), onPressed: _busy ? null : _search),
          ),
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: Center(child: CircularProgressIndicator())),
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
        if (_phoneCanRead)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _typing = false;
                      _message = null;
                      _results = const [];
                    });
                    _refresh();
                  },
            icon: const Icon(Icons.nfc_rounded),
            label: const Text('Tap the card on this phone instead'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final nfc = _nfc;
    final Widget body;
    if (nfc == null) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else if (_typing || !_phoneCanRead) {
      body = _typePanel();
    } else {
      final Widget panel = _allowed != true
          ? _allowPanel()
          : nfc == NfcSupport.disabled
              ? _nfcOffPanel()
              : _tapPanel();
      // The counter reader works on every panel without a text box.
      body = Focus(focusNode: _keyFocus, autofocus: true, onKeyEvent: _onKey, child: panel);
    }
    return AlertDialog(
      title: const Text('Tap loyalty card'),
      content: SingleChildScrollView(child: body),
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
    // Rounded to centavos so the change and the "at least the total" check
    // compare exact peso amounts.
    _controller.addListener(
      () => setState(() => _received = roundMoney(double.tryParse(_controller.text) ?? 0)),
    );
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
    final receivedCents = toCents(_received);
    final amountCents = toCents(amount);
    final double change =
        receivedCents > amountCents ? (receivedCents - amountCents) / 100 : 0;

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
          // Also stores the full receipt on the device (offline e-receipts).
          future: store.fetchOrderWithReceipt(sale.orderId),
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
                      if (sale.pointsRedeemed > 0) ...[
                        _row('Subtotal', peso(sale.subtotal)),
                        _row('Points used (${sale.pointsRedeemed} pts)', '−${peso(sale.loyaltyDiscount)}'),
                      ],
                      _row('Total', peso(sale.total), bold: true),
                      if (order != null) _row('Paid with', order.paymentMethod),
                      if (order?.cashReceived != null) _row('Cash received', peso(order!.cashReceived!)),
                      if (sale.change > 0) _row('Change', peso(sale.change)),
                      if (sale.pointsEarned > 0) _row('Loyalty points earned', '+${sale.pointsEarned}'),
                      if (sale.alreadyRecorded)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('This sale was already recorded. It was not charged twice.', style: AppTextStyles.bodySm),
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
