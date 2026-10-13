import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import '../../core/services/branch_controller.dart';
import '../../core/services/customer_data_store.dart';
import '../../data/catalog_store.dart';
import '../../data/models/product.dart';
import '../../data/repositories/branch_repository.dart';
import '../../data/repositories/cart_repository.dart';
import '../../data/repositories/icon_registry.dart';
import '../../data/repositories/products_repository.dart';
import '../settings/screens/branch_settings_screen.dart';
import 'screens/cart_screen.dart';
import '../../core/utils/app_error.dart';
import '../../core/utils/format_utils.dart';

class CartLine {
  final String id;
  final Product product;
  final ProductVariant variant;
  double unitPrice;
  int quantity;

  CartLine({
    required this.id,
    required this.product,
    required this.variant,
    required this.unitPrice,
    this.quantity = 1,
  });

  double get lineTotal => toCents(unitPrice) * quantity / 100;
}

class CartController extends ChangeNotifier {
  CartController._();
  static final CartController instance = CartController._();

  final List<CartLine> _lines = [];
  List<CartLine> get lines => List.unmodifiable(_lines);

  String? _firebaseUid;
  String? _branchId;
  String? _cartId;
  String? _storageKey;
  bool _dirty = false;
  bool _syncing = false;
  Future<String?>? _syncFuture;
  Timer? _retryTimer;
  int _revision = 0;

  String? appliedVoucherCode;
  bool redeemPoints = false;
  CartPricing _pricing = const CartPricing(
    subtotal: 0,
    voucherDiscount: 0,
    loyaltyDiscount: 0,
    deliveryFee: 0,
    total: 0,
    voucherCode: null,
    redeemPoints: false,
    loyaltyPointsBalance: 0,
    loyaltyPointsUsed: 0,
  );

  String? lastError;
  bool get isSyncing => _syncing;

  bool _hydrating = false;
  bool _hydrateFailed = false;

  /// True while the saved cart is being loaded from the server (e.g. right
  /// after sign-in or a branch switch). The cart screen shows a loading state
  /// instead of "Your cart is empty" while this is true.
  bool get isHydrating => _hydrating;

  /// True when loading the saved cart failed and nothing has succeeded since.
  /// [lastError] holds the customer-safe message; call [retryLoad] to retry.
  bool get hasLoadError => _hydrateFailed;

  /// Retries loading the saved cart after a failure.
  Future<void> retryLoad() async {
    final uid = _firebaseUid;
    if (uid == null) return;
    await hydrate(uid, branchId: _branchId);
  }
  int get loyaltyPointsBalance => _pricing.loyaltyPointsBalance;
  int get loyaltyPointsUsed => _pricing.loyaltyPointsUsed;
  double get subtotal => _pricing.subtotal;
  double get voucherDiscount => _pricing.voucherDiscount;
  double get loyaltyDiscount => _pricing.loyaltyDiscount;
  double get deliveryFee => _pricing.deliveryFee;
  double get total => _pricing.total;
  int get itemCount => _lines.fold(0, (sum, line) => sum + line.quantity);
  String get currentBranch => BranchController.instance.selectedBranch?.name ?? 'Select a branch';
  String? get cartId => _cartId;
  String? get branchId => _branchId;

  /// True while local cart edits (made offline or during an outage) have not
  /// been accepted by the server yet. The saved snapshot keeps them safe;
  /// this lets the UI say so honestly instead of implying they're synced.
  bool get hasUnsyncedChanges => _dirty;

  SharedPreferencesAsync? _prefs;

  Future<SharedPreferencesAsync> get _storage async {
    _prefs ??= SharedPreferencesAsync();
    return _prefs!;
  }

  String _keyFor(String uid, String branchId) => 'melai_cart_v3_${uid}_$branchId';

  Future<void> hydrate(String firebaseUid, {String? branchId}) async {
    _firebaseUid = firebaseUid;
    final resolvedBranch = branchId ?? await _resolveBranchId();
    if (resolvedBranch == null) {
      _branchId = null;
      _storageKey = null;
      _cartId = null;
      _dirty = false;
      _clearMemoryOnly();
      notifyListeners();
      return;
    }

    _branchId = resolvedBranch;
    _storageKey = _keyFor(firebaseUid, resolvedBranch);
    await _loadLocalSnapshot();

    _hydrating = true;
    _hydrateFailed = false;
    notifyListeners();
    try {
      // The catalog may still be loading (main.dart starts it without
      // waiting) or may not load at all offline. Load it first so remote
      // lines resolve to real products; if it can't load, lines are still
      // kept (see [_lineFromRemote]).
      await _ensureCatalogLoaded(resolvedBranch);
      final remote = await CartRepository.instance.loadOpenCart(branchId: resolvedBranch);
      if (remote != null && !_dirty) {
        _applyRemoteState(remote);
        await _saveLocalSnapshot(dirty: false);
      } else if (remote != null && _dirty) {
        await _syncNow();
      } else if (remote == null && _dirty) {
        await _syncNow();
      } else {
        _dirty = false;
        _clearMemoryOnly();
        await _saveLocalSnapshot(dirty: false);
        notifyListeners();
      }
    } catch (e) {
      _hydrateFailed = true;
      lastError = _messageFor(e);
      notifyListeners();
      _scheduleRetry();
    } finally {
      _hydrating = false;
      notifyListeners();
    }
  }

  /// Loads the catalog for [branchId] when nothing is loaded yet. Never
  /// throws: a missing catalog must not stop the cart from loading.
  Future<void> _ensureCatalogLoaded(String branchId) async {
    if (kProducts.isNotEmpty) return;
    try {
      await catalogLoader(branchId);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'cart_controller:ensureCatalogLoaded');
    }
  }

  /// Loads the product catalog for a branch. Tests replace it.
  @visibleForTesting
  Future<void> Function(String branchId) catalogLoader =
      (branchId) => ProductsRepository.instance.loadCatalog(branchId: branchId);

  /// In-memory stand-in for the device's saved cart snapshots. Tests only;
  /// null means the real device storage is used.
  @visibleForTesting
  Map<String, String>? debugSnapshotStorage;

  Future<String?> _readSnapshot(String key) async {
    final memory = debugSnapshotStorage;
    if (memory != null) return memory[key];
    return (await _storage).getString(key);
  }

  Future<void> _writeSnapshot(String key, String value) async {
    final memory = debugSnapshotStorage;
    if (memory != null) {
      memory[key] = value;
      return;
    }
    await (await _storage).setString(key, value);
  }

  Future<void> _removeSnapshot(String key) async {
    final memory = debugSnapshotStorage;
    if (memory != null) {
      memory.remove(key);
      return;
    }
    await (await _storage).remove(key);
  }

  Future<String?> _resolveBranchId() async {
    final selected = BranchController.instance.selectedBranch;
    if (selected != null) return selected.id;
    final defaultId = CustomerDataStore.instance.profile?.defaultBranchId;
    if (defaultId != null) return defaultId;
    return null;
  }

  Future<bool> switchBranch(String branchId) async {
    final uid = _firebaseUid;
    if (uid == null) {
      _branchId = branchId;
      _storageKey = null;
      _clearMemoryOnly();
      notifyListeners();
      return true;
    }
    final error = await _flushCurrentBranch();
    if (error != null && _dirty) {
      lastError = error;
      notifyListeners();
      return false;
    }
    await hydrate(uid, branchId: branchId);
    return true;
  }

  Future<String?> _flushCurrentBranch() async {
    if (!_dirty || _firebaseUid == null || _branchId == null) return null;
    return _syncNow();
  }

  Future<void> _loadLocalSnapshot() async {
    final key = _storageKey;
    if (key == null) return;
    final raw = await _readSnapshot(key);
    if (raw == null || raw.isEmpty) {
      _dirty = false;
      _clearMemoryOnly();
      return;
    }
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _cartId = map['cart_id'] as String?;
      appliedVoucherCode = map['voucher_code'] as String?;
      redeemPoints = map['redeem_points'] as bool? ?? false;
      _dirty = map['dirty'] as bool? ?? false;
      final savedPricing = map['pricing'];
      _pricing = savedPricing is Map
          ? CartPricing.fromJson(Map<String, dynamic>.from(savedPricing))
          : _localPricing();
      _lines.clear();
      for (final rawItem in (map['items'] as List? ?? const [])) {
        final item = Map<String, dynamic>.from(rawItem as Map);
        final productId = item['product_id'] as String?;
        final variantId = item['variant_id'] as String?;
        if (productId == null) continue;
        final quantity = (item['quantity'] as num?)?.toInt();
        if (quantity == null || quantity <= 0) continue;
        final variantLabel = item['variant_label'] as String?;
        // Catalog first (fresh names/prices); when it isn't loaded yet, the
        // product saved with the line. A line is never dropped just because
        // the catalog is missing.
        ProductVariant? variant;
        Product? product = tryFindProductById(productId);
        if (product != null) variant = _matchVariant(product, variantId, variantLabel);
        if (variant == null) {
          product = _productFromSnapshot(item['product_snapshot']);
          if (product != null) variant = _matchVariant(product, variantId, variantLabel);
        }
        if (product == null || variant == null) continue;
        _lines.add(
          CartLine(
            id: '${product.id}_${variant.id}',
            product: product,
            variant: variant,
            unitPrice: (item['unit_price'] as num?)?.toDouble() ?? variant.price,
            quantity: quantity,
          ),
        );
      }
      if (_lines.isNotEmpty && savedPricing == null) {
        _pricing = _localPricing();
      }
      notifyListeners();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'cart_controller:239');
      await _removeSnapshot(key);
      _clearMemoryOnly();
    }
  }

  CartPricing _localPricing() {
    // Summed in centavos (see toCents): adding doubles drifts by fractions of
    // a centavo (90.30000000000001), which breaks later comparisons.
    final subtotalCents = _lines.fold<int>(0, (sum, line) => sum + toCents(line.unitPrice) * line.quantity);
    final subtotal = subtotalCents / 100;
    final deliveryFee = BranchController.instance.selectedBranch?.deliveryFee ?? 0.0;
    return CartPricing(
      subtotal: subtotal,
      voucherDiscount: 0,
      loyaltyDiscount: 0,
      deliveryFee: deliveryFee,
      total: (subtotalCents + toCents(deliveryFee)) / 100,
      voucherCode: appliedVoucherCode,
      redeemPoints: redeemPoints,
      loyaltyPointsBalance: _pricing.loyaltyPointsBalance,
      loyaltyPointsUsed: 0,
    );
  }

  void _applyRemoteState(CartRemoteState remote) {
    // Copied BEFORE clearing: these are the fallback for lines whose product
    // isn't in the loaded catalog.
    final previousLines = List<CartLine>.from(_lines);
    _cartId = remote.cartId;
    appliedVoucherCode = remote.voucherCode;
    redeemPoints = remote.redeemPoints;
    _pricing = remote.pricing;
    _lines.clear();
    for (final item in remote.items) {
      if (item.quantity <= 0) continue;
      _lines.add(_lineFromRemote(item, previousLines));
    }
    _dirty = false;
    _revision++;
    lastError = null;
    notifyListeners();
  }

  ProductVariant? _matchVariant(Product product, String? variantId, String? variantLabel) {
    for (final v in product.variants) {
      if (v.id == variantId) return v;
    }
    if (variantLabel == null) return null;
    for (final v in product.variants) {
      if (v.label == variantLabel) return v;
    }
    return null;
  }

  /// Builds a cart line for a server cart item. Never drops the item: when
  /// the catalog doesn't have its product (not loaded yet / offline), the
  /// line seen before is reused, or one is built from the server's own
  /// fields. Otherwise the next sync would delete it on the server.
  CartLine _lineFromRemote(CartRemoteItem item, List<CartLine> previousLines) {
    final product = tryFindProductById(item.productId);
    if (product != null) {
      final variant = _matchVariant(product, item.variantId, item.variantLabel);
      if (variant != null) {
        return CartLine(
          id: '${product.id}_${variant.id}',
          product: product,
          variant: variant,
          unitPrice: item.currentPrice,
          quantity: item.quantity,
        );
      }
    }
    for (final line in previousLines) {
      if (line.product.id == item.productId && line.variant.id == item.variantId) {
        line.quantity = item.quantity;
        line.unitPrice = item.currentPrice;
        return line;
      }
    }
    final variant = ProductVariant(id: item.variantId, label: item.variantLabel, price: item.currentPrice);
    final placeholder = Product(
      id: item.productId,
      name: 'Saved item',
      variantLabel: item.variantLabel,
      categoryId: '',
      price: item.currentPrice,
      rating: 0,
      reviewCount: 0,
      stockLabel: 'Unknown',
      description: '',
      branchAvailability: const [],
      variants: [variant],
      icon: Icons.inventory_2_outlined,
      color: Colors.grey,
    );
    return CartLine(
      id: '${item.productId}_${item.variantId}',
      product: placeholder,
      variant: variant,
      unitPrice: item.currentPrice,
      quantity: item.quantity,
    );
  }

  Future<void> _saveLocalSnapshot({required bool dirty}) async {
    final key = _storageKey;
    if (key == null) return;
    final payload = {
      'cart_id': _cartId,
      'branch_id': _branchId,
      'voucher_code': appliedVoucherCode,
      'redeem_points': redeemPoints,
      'dirty': dirty,
      'updated_at': DateTime.now().toIso8601String(),
      'pricing': _pricing.toJson(),
      'items': [
        for (final line in _lines)
          {
            'product_id': line.product.id,
            'variant_id': line.variant.id,
            'variant_label': line.variant.label,
            'quantity': line.quantity,
            'unit_price': line.unitPrice,
            'product_snapshot': _productToSnapshot(line.product),
          },
      ],
    };
    await _writeSnapshot(key, jsonEncode(payload));
  }

  void _markDirty() {
    _dirty = true;
    _revision++;
    unawaited(_saveLocalSnapshot(dirty: true));
    notifyListeners();
    unawaited(_syncNow());
  }

  Future<String?> _syncNow() {
    final existing = _syncFuture;
    if (existing != null) return existing;
    final future = _syncLoop();
    _syncFuture = future;
    future.whenComplete(() {
      if (identical(_syncFuture, future)) {
        _syncFuture = null;
      }
    });
    return future;
  }

  Future<String?> _syncLoop() async {
    if (_firebaseUid == null || _branchId == null || !_dirty) return null;
    _syncing = true;
    notifyListeners();
    try {
      while (_dirty) {
        final sentRevision = _revision;
        final branch = _branchId!;
        final result = await CartRepository.instance.syncCart(
          branchId: branch,
          voucherCode: appliedVoucherCode,
          redeemPoints: redeemPoints,
          items: [
            for (final line in _lines)
              {
                'product_id': line.product.id,
                'variant_id': line.variant.id,
                'quantity': line.quantity,
              },
          ],
        );
        if (_branchId != branch) return null;
        _cartId = result.cartId;
        _pricing = result.pricing;
        appliedVoucherCode = result.voucherCode;
        redeemPoints = result.redeemPoints;
        lastError = null;
        _hydrateFailed = false;
        if (_revision == sentRevision) {
          _dirty = false;
          await _saveLocalSnapshot(dirty: false);
          notifyListeners();
        }
      }
      _retryTimer?.cancel();
      _retryTimer = null;
      return null;
    } catch (e) {
      final message = _messageFor(e);
      if (!isServerRefusal(e)) {
        // Offline / timeout / session expired: the server never judged this
        // cart, so keep the edits and send them again later.
        lastError = message;
        _scheduleRetry();
        notifyListeners();
        return lastError;
      }
      // The server answered and refused this cart (e.g. not enough stock).
      // Sending the same cart again would fail forever, so stop retrying and
      // show what the server really holds; the message tells the customer
      // what to fix.
      _retryTimer?.cancel();
      _retryTimer = null;
      await _reloadServerCartAfterRefusal();
      lastError = message;
      notifyListeners();
      return message;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// True when [error] is the server answering "no" to the request (a
  /// business rule), not a connection / session / temporary server problem.
  @visibleForTesting
  static bool isServerRefusal(Object error) {
    if (error is! PostgrestException) return false;
    final kind = AppErrors.from(error, scope: ErrorScope.cart).kind;
    if (kind == AppErrorKind.noInternet || kind == AppErrorKind.timeout || kind == AppErrorKind.authExpired) {
      return false;
    }
    final code = error.code ?? '';
    // Temporary server trouble (HTTP 5xx, connection/resource classes,
    // serialization failures): worth retrying.
    if (code.startsWith('5') || code.startsWith('08') || code == '40001' || code == '40P01') {
      return false;
    }
    return true;
  }

  Future<void> _reloadServerCartAfterRefusal() async {
    final branch = _branchId;
    if (branch == null) return;
    try {
      final remote = await CartRepository.instance.loadOpenCart(branchId: branch);
      if (_branchId != branch) return;
      if (remote == null) {
        _dirty = false;
        _clearMemoryOnly();
      } else {
        _applyRemoteState(remote);
      }
      await _saveLocalSnapshot(dirty: false);
    } catch (caughtError, caughtStack) {
      // Couldn't read the server cart: keep the local edits marked unsynced
      // (checkout stays blocked); the customer's next edit tries again.
      AppErrors.report(caughtError, caughtStack, 'cart_controller:reloadAfterRefusal', scope: ErrorScope.cart);
    }
  }

  /// Tests only: whether an automatic re-send is waiting.
  @visibleForTesting
  bool get debugRetryScheduled => _retryTimer?.isActive ?? false;

  /// Sends any unsynced edits now and waits for the answer. Returns null when
  /// the server holds exactly this cart; otherwise a customer-ready message.
  /// Checkout calls this first: `place_order` uses the server's cart, so it
  /// must never run while the screen shows something else.
  Future<String?> flush() async {
    final error = await _syncNow();
    if (error != null) return error;
    if (_dirty) {
      return 'Your cart is still saving. Please check your connection and try again.';
    }
    return null;
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(const Duration(seconds: 15), () {
      unawaited(_syncNow());
    });
  }

  Future<void> refresh({bool? isDelivery}) async {
    if (_branchId == null || _firebaseUid == null) return;
    // Never let a server refresh overwrite edits the server hasn't seen yet
    // (e.g. items added while offline). Push them first; if that still
    // can't reach the server, keep the local edits and try again later
    // (the retry timer keeps running).
    if (_dirty) {
      await _syncNow();
      if (_dirty) return;
    }
    if (kProducts.isEmpty) {
      await ProductsRepository.instance.loadCatalog(branchId: _branchId);
    }
    final remote = await CartRepository.instance.loadOpenCart(branchId: _branchId!);
    if (remote == null) {
      _dirty = false;
      _clearMemoryOnly();
      await _saveLocalSnapshot(dirty: false);
      notifyListeners();
      return;
    }
    _applyRemoteState(remote);
    if (isDelivery != null) {
      await _refreshDeliveryPricing(isDelivery);
    }
    await _saveLocalSnapshot(dirty: false);
  }

  Future<void> _refreshDeliveryPricing(bool isDelivery) async {
    if (_firebaseUid == null || _branchId == null || _cartId == null) return;
    final result = await CartRepository.instance.getPricing(
      cartId: _cartId!,
      isDelivery: isDelivery,
    );
    _pricing = result;
    notifyListeners();
  }

  Future<CartPricing?> pricingFor({required bool isDelivery}) async {
    if (_branchId == null || _firebaseUid == null || _cartId == null) return null;
    final pricing = await CartRepository.instance.getPricing(cartId: _cartId!, isDelivery: isDelivery);
    _pricing = pricing;
    notifyListeners();
    return pricing;
  }

  Future<String?> applyVoucher(String code) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      clearVoucher();
      return null;
    }
    if (normalized != appliedVoucherCode) {
      // Counted (and limited) by the database before the cart may use the code.
      try {
        await CartRepository.instance.registerVoucherAttempt(normalized);
      } catch (e) {
        lastError = _messageFor(e);
        notifyListeners();
        return lastError;
      }
    }
    final previous = appliedVoucherCode;
    appliedVoucherCode = normalized;
    _markDirty();
    final error = await _syncNow();
    if (error != null) {
      // Refused by the server: the cart was reloaded from the server, which
      // still holds the previous choice. Nothing to undo locally.
      if (!_dirty) return error;
      appliedVoucherCode = previous;
      _dirty = true;
      _revision++;
      await _saveLocalSnapshot(dirty: true);
      notifyListeners();
      return error;
    }
    return null;
  }

  void clearVoucher() {
    appliedVoucherCode = null;
    _markDirty();
  }

  Future<String?> setRedeemPoints(bool enabled) async {
    final previous = redeemPoints;
    redeemPoints = enabled;
    _markDirty();
    final error = await _syncNow();
    if (error != null) {
      // Refused by the server: the cart was reloaded from the server, which
      // still holds the previous choice. Nothing to undo locally.
      if (!_dirty) return error;
      redeemPoints = previous;
      _dirty = true;
      _revision++;
      await _saveLocalSnapshot(dirty: true);
      notifyListeners();
      return error;
    }
    return null;
  }

  /// Adds to the cart, capped by [stockOverride] (or the variant's cached
  /// stock). Returns how many were added and, when none were, WHY — callers
  /// must show [AddToCartResult.message], never assume "out of stock".
  AddToCartResult addProduct(Product product, ProductVariant variant, {int quantity = 1, int? stockOverride}) {
    if (quantity <= 0) return AddToCartResult.failed(AddToCartFailure.invalidQuantity, requested: quantity);
    if (_firebaseUid == null) {
      return AddToCartResult.failed(AddToCartFailure.notSignedIn, requested: quantity);
    }
    if (_branchId == null) {
      return AddToCartResult.failed(AddToCartFailure.noBranch, requested: quantity);
    }
    final lineId = '${product.id}_${variant.id}';
    final index = _lines.indexWhere((line) => line.id == lineId);
    final currentQty = index == -1 ? 0 : _lines[index].quantity;
    final stock = stockOverride ?? variant.stockOnHand;
    var addable = quantity;
    if (stock != null) {
      if (stock <= 0) {
        return AddToCartResult.failed(AddToCartFailure.outOfStock, requested: quantity);
      }
      final remaining = stock - currentQty;
      if (remaining <= 0) {
        return AddToCartResult.failed(
          AddToCartFailure.cartAtStockLimit,
          requested: quantity,
          message: 'You already have all $stock available in your cart.',
        );
      }
      if (remaining < addable) addable = remaining;
    }
    if (index == -1) {
      _lines.add(CartLine(
        id: lineId,
        product: product,
        variant: variant,
        unitPrice: variant.price,
        quantity: addable,
      ));
    } else {
      _lines[index].quantity += addable;
    }
    _pricing = _localPricing();
    _markDirty();
    return AddToCartResult.added(addable, requested: quantity);
  }

  /// The signed-in customer this cart belongs to, or null.
  String? get signedInUid => _firebaseUid;

  /// Tests only: binds the cart to [uid] / [branchId] without loading
  /// anything from storage or the server.
  @visibleForTesting
  void debugBind(String? uid, {String? branchId}) {
    _firebaseUid = uid;
    _branchId = branchId;
    _storageKey = null;
    _dirty = false;
    _clearMemoryOnly();
  }

  /// Re-checks stock at the customer's branch right now, then adds.
  ///
  /// "Out of stock" is only reported when the branch's live stock is really
  /// 0. Not signed in, no branch chosen, not stocked at this branch, a
  /// failed branch switch and a failed stock check each get their own
  /// [AddToCartFailure].
  Future<AddToCartResult> addProductWithLiveCheck(Product product, ProductVariant variant, {int quantity = 1}) async {
    // Don't let an old message (e.g. from a previous attempt) be shown for
    // this one. A message about edits still waiting to sync stays: it is
    // still true.
    if (!_dirty) lastError = null;
    if (quantity <= 0) return AddToCartResult.failed(AddToCartFailure.invalidQuantity, requested: quantity);
    if (!product.isActive) return AddToCartResult.failed(AddToCartFailure.unavailable, requested: quantity);
    if (_firebaseUid == null) {
      return AddToCartResult.failed(AddToCartFailure.notSignedIn, requested: quantity);
    }
    final branchId = BranchController.instance.selectedBranch?.id ?? _branchId;
    if (branchId == null) {
      return AddToCartResult.failed(AddToCartFailure.noBranch, requested: quantity);
    }
    if (_branchId != branchId) {
      final switched = await switchBranch(branchId);
      if (!switched) {
        return AddToCartResult.failed(
          AddToCartFailure.branchSwitchFailed,
          requested: quantity,
          message: lastError,
        );
      }
    }
    final live = await ProductsRepository.instance.checkLiveStock(
      productId: product.id,
      variantId: variant.id,
      branchId: branchId,
    );
    if (live.notStockedHere) {
      return AddToCartResult.failed(AddToCartFailure.notStockedHere, requested: quantity);
    }
    if (live.failed) {
      // Couldn't verify. Use the last known stock only when it says there
      // is some — never claim "out of stock" from data we couldn't confirm.
      // The server re-checks stock when the cart syncs and at checkout.
      final cached = variant.stockOnHand;
      final inCart = quantityFor(product.id, variant.label);
      if (cached != null && cached - inCart <= 0) {
        return AddToCartResult.failed(AddToCartFailure.checkFailed, requested: quantity);
      }
      return addProduct(product, variant, quantity: quantity, stockOverride: cached).asUnverified();
    }
    return addProduct(product, variant, quantity: quantity, stockOverride: live.quantity);
  }

  Future<void> updateQuantity(String lineId, int quantity) async {
    final index = _lines.indexWhere((line) => line.id == lineId);
    if (index == -1) return;
    if (quantity <= 0) {
      _lines.removeAt(index);
    } else {
      _lines[index].quantity = quantity;
    }
    _pricing = _localPricing();
    _markDirty();
    if (_firebaseUid != null && _branchId != null) {
      await _syncNow();
    }
  }

  Future<void> removeLine(String lineId) async {
    final index = _lines.indexWhere((line) => line.id == lineId);
    if (index == -1) return;
    _lines.removeAt(index);
    _pricing = _localPricing();
    _markDirty();
    if (_firebaseUid != null && _branchId != null) {
      await _syncNow();
    }
  }

  /// Undo for [removeLine]: puts [line] back at [index] (or the end).
  Future<void> restoreLine(CartLine line, int index) async {
    if (_lines.any((l) => l.id == line.id)) return;
    _lines.insert(index.clamp(0, _lines.length).toInt(), line);
    _pricing = _localPricing();
    _markDirty();
    if (_firebaseUid != null && _branchId != null) {
      await _syncNow();
    }
  }

  Future<void> clear() async {
    _lines.clear();
    appliedVoucherCode = null;
    redeemPoints = false;
    _pricing = _localPricing();
    _markDirty();
    if (_firebaseUid != null && _branchId != null) {
      await _syncNow();
    }
  }

  Future<void> completeCheckout() async {
    final key = _storageKey;
    _lines.clear();
    _cartId = null;
    appliedVoucherCode = null;
    redeemPoints = false;
    _dirty = false;
    _pricing = const CartPricing(
      subtotal: 0,
      voucherDiscount: 0,
      loyaltyDiscount: 0,
      deliveryFee: 0,
      total: 0,
      voucherCode: null,
      redeemPoints: false,
      loyaltyPointsBalance: 0,
      loyaltyPointsUsed: 0,
    );
    if (key != null) await _removeSnapshot(key);
    notifyListeners();
  }

  void endSession() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _firebaseUid = null;
    _branchId = null;
    _storageKey = null;
    _cartId = null;
    _dirty = false;
    _clearMemoryOnly();
    notifyListeners();
  }

  int quantityFor(String productId, String variantLabel) {
    final matches = _lines.where((line) => line.product.id == productId && line.variant.label == variantLabel);
    return matches.isEmpty ? 0 : matches.first.quantity;
  }

  void _clearMemoryOnly() {
    _lines.clear();
    appliedVoucherCode = null;
    redeemPoints = false;
    _cartId = null;
    _pricing = const CartPricing(
      subtotal: 0,
      voucherDiscount: 0,
      loyaltyDiscount: 0,
      deliveryFee: 0,
      total: 0,
      voucherCode: null,
      redeemPoints: false,
      loyaltyPointsBalance: 0,
      loyaltyPointsUsed: 0,
    );
  }

  Map<String, dynamic> _productToSnapshot(Product product) {
    return {
      'id': product.id,
      'name': product.name,
      'variant_label': product.variantLabel,
      'category_id': product.categoryId,
      'price': product.price,
      'original_price': product.originalPrice,
      'rating': product.rating,
      'review_count': product.reviewCount,
      'badge': product.badge,
      'stock_label': product.stockLabel,
      'description': product.description,
      'branch_availability': product.branchAvailability,
      'spice_levels': product.spiceLevels,
      'icon_name': IconRegistry.nameFor(product.icon),
      'color_value': product.color.toARGB32(),
      'images': product.images,
      'sku': product.sku,
      'cost_price': product.costPrice,
      'is_active': product.isActive,
      'tags': product.tags,
      'units_sold_last_30_days': product.unitsSoldLast30Days,
      'is_featured': product.isFeatured,
      'variants': [
        for (final variant in product.variants)
          {
            'id': variant.id,
            'label': variant.label,
            'price': variant.price,
            'badge': variant.badge,
            'cost_price': variant.costPrice,
            'sku': variant.sku,
            'stock_on_hand': variant.stockOnHand,
          },
      ],
    };
  }

  Product? _productFromSnapshot(dynamic raw) {
    if (raw is! Map) return null;
    try {
      final map = Map<String, dynamic>.from(raw);
      final variants = (map['variants'] as List? ?? const [])
          .whereType<Map>()
          .map((rawVariant) {
            final variant = Map<String, dynamic>.from(rawVariant);
            return ProductVariant(
              id: variant['id'] as String? ?? '',
              label: variant['label'] as String? ?? '',
              price: (variant['price'] as num?)?.toDouble() ?? 0,
              badge: variant['badge'] as String?,
              costPrice: (variant['cost_price'] as num?)?.toDouble(),
              sku: variant['sku'] as String?,
              stockOnHand: (variant['stock_on_hand'] as num?)?.toInt(),
            );
          })
          .toList();
      return Product(
        id: map['id'] as String,
        name: map['name'] as String,
        variantLabel: map['variant_label'] as String? ?? '',
        categoryId: map['category_id'] as String? ?? '',
        price: (map['price'] as num?)?.toDouble() ?? 0,
        originalPrice: (map['original_price'] as num?)?.toDouble(),
        rating: (map['rating'] as num?)?.toDouble() ?? 0,
        reviewCount: (map['review_count'] as num?)?.toInt() ?? 0,
        badge: map['badge'] as String?,
        stockLabel: map['stock_label'] as String? ?? 'Unknown',
        description: map['description'] as String? ?? '',
        branchAvailability: List<String>.from(map['branch_availability'] as List? ?? const []),
        variants: variants,
        spiceLevels: List<String>.from(map['spice_levels'] as List? ?? const []),
        // Resolved through the registry's constant icons (never built from raw
        // code points at runtime). Falls back to the legacy code-point key.
        icon: IconRegistry.icon(
          map['icon_name'] as String? ??
              IconRegistry.nameForCodePoint((map['icon_code_point'] as num?)?.toInt()),
          fallback: Icons.inventory_2_outlined,
        ),
        color: Color((map['color_value'] as num?)?.toInt() ?? Colors.grey.toARGB32()),
        images: List<String>.from(map['images'] as List? ?? const []),
        sku: map['sku'] as String? ?? '',
        costPrice: (map['cost_price'] as num?)?.toDouble() ?? 0,
        isActive: map['is_active'] as bool? ?? true,
        tags: List<String>.from(map['tags'] as List? ?? const []),
        unitsSoldLast30Days: (map['units_sold_last_30_days'] as num?)?.toInt() ?? 0,
        isFeatured: map['is_featured'] as bool? ?? false,
      );
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'cart_controller:746');
      return null;
    }
  }

  String _messageFor(Object e) {
    // AppErrors.from maps any error to customer-safe wording (no SQL / internals).
    final text = AppErrors.from(e, scope: ErrorScope.cart).message.trim();
    return text.isEmpty ? 'Cart sync failed. We will retry when the connection is available.' : text;
  }
}

/// Why an add-to-cart attempt added nothing.
enum AddToCartFailure {
  invalidQuantity,
  notSignedIn,
  noBranch,
  branchSwitchFailed,
  unavailable,
  notStockedHere,
  outOfStock,
  cartAtStockLimit,
  checkFailed,
}

/// What an add-to-cart attempt did: how many units were added, and if none,
/// the [failure] reason with a customer-ready [message].
class AddToCartResult {
  final int added;
  final int requested;
  final AddToCartFailure? failure;
  final String? _message;

  /// Added while the live stock check was unavailable (cached stock used).
  final bool stockUnverified;

  const AddToCartResult._(this.added, this.requested, this.failure, this._message, this.stockUnverified);

  const AddToCartResult.added(int added, {required int requested})
      : this._(added, requested, null, null, false);

  const AddToCartResult.failed(AddToCartFailure failure, {required int requested, String? message})
      : this._(0, requested, failure, message, false);

  AddToCartResult asUnverified() => AddToCartResult._(added, requested, failure, _message, added > 0);

  bool get ok => added > 0;
  bool get isPartial => added > 0 && added < requested;

  /// Customer-facing reason when nothing was added (null when [ok]).
  String? get message => failure == null ? null : (_message ?? messageFor(failure!));

  static String messageFor(AddToCartFailure failure) {
    switch (failure) {
      case AddToCartFailure.invalidQuantity:
        return 'Please choose a quantity of at least 1.';
      case AddToCartFailure.notSignedIn:
        return 'Please sign in before adding items to your cart.';
      case AddToCartFailure.noBranch:
        return 'Please select a branch first.';
      case AddToCartFailure.branchSwitchFailed:
        return 'We couldn\'t switch branches while your cart is waiting to sync. Please try again in a moment.';
      case AddToCartFailure.unavailable:
        return 'This item is no longer available.';
      case AddToCartFailure.notStockedHere:
        return 'This item isn\'t sold at your selected branch. Try another branch.';
      case AddToCartFailure.outOfStock:
        return 'This item is out of stock at your selected branch.';
      case AddToCartFailure.cartAtStockLimit:
        return 'You already have all available stock of this item in your cart.';
      case AddToCartFailure.checkFailed:
        return 'We couldn\'t check stock right now. Please check your connection and try again.';
    }
  }
}

/// Makes sure a signed-in customer has a branch before adding to the cart.
/// Auto-selects the only open customer branch; otherwise opens the branch
/// picker. Returns true when a branch is selected afterwards.
Future<bool> ensureBranchSelected(BuildContext context) async {
  if (BranchController.instance.selectedBranch != null) return true;
  if (kBranches.isEmpty) {
    try {
      await BranchRepository.instance.loadBranches();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'cart_controller:ensureBranchSelected');
    }
  }
  if (!context.mounted) return false;
  final open = kBranches.where((b) => b.servesCustomers && b.isActive).toList();
  if (open.length == 1) {
    final branch = open.single;
    final cart = CartController.instance;
    if (cart.signedInUid != null) {
      final switched = await cart.switchBranch(branch.id);
      if (!switched) return false;
    }
    await BranchController.instance.selectBranch(branch, firebaseUid: cart.signedInUid);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Shopping at ${branch.name}. You can change this in Settings.')),
      );
    }
    return BranchController.instance.selectedBranch != null;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const BranchSettingsScreen()),
  );
  return BranchController.instance.selectedBranch != null;
}

/// [CartController.addProductWithLiveCheck], but when the only problem is
/// that no branch is chosen yet, asks for one (see [ensureBranchSelected])
/// and tries again.
Future<AddToCartResult> addToCartWithBranchPrompt(
  BuildContext context,
  Product product,
  ProductVariant variant, {
  int quantity = 1,
}) async {
  final cart = CartController.instance;
  final first = await cart.addProductWithLiveCheck(product, variant, quantity: quantity);
  if (first.failure != AddToCartFailure.noBranch || !context.mounted) return first;
  final picked = await ensureBranchSelected(context);
  if (!picked || !context.mounted) return first;
  return cart.addProductWithLiveCheck(product, variant, quantity: quantity);
}

/// Shown under a successful add when live stock couldn't be confirmed.
const String kStockUnverifiedNote = 'We couldn\'t confirm live stock — it will be checked again at checkout.';

Future<void> addToCartWithFeedback(
  BuildContext context,
  Product product,
  ProductVariant variant, {
  int quantity = 1,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await addToCartWithBranchPrompt(context, product, variant, quantity: quantity);
  if (!context.mounted) return;
  if (!result.ok) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message ?? 'We couldn\'t add this item. Please try again.')));
    return;
  }
  final added = result.added;
  var message = result.isPartial
      ? 'Only $added available — added $added to cart.'
      : 'Added ${product.name} to cart';
  if (result.stockUnverified) message = '$message $kStockUnverifiedNote';
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: 'View Cart',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CartScreen()),
        ),
      ),
    ),
  );
}
