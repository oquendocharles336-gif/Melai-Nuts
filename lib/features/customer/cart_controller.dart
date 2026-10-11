import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/branch_controller.dart';
import '../../core/services/customer_data_store.dart';
import '../../data/catalog_store.dart';
import '../../data/models/product.dart';
import '../../data/repositories/cart_repository.dart';
import '../../data/repositories/icon_registry.dart';
import '../../data/repositories/products_repository.dart';
import 'screens/cart_screen.dart';

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

  double get lineTotal => unitPrice * quantity;
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
    final prefs = await _storage;
    final raw = await prefs.getString(key);
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
        Product? product;
        try {
          product = findProductById(productId);
        } catch (_) {
          product = null;
        }
        product ??= _productFromSnapshot(item['product_snapshot']);
        if (product == null) continue;
        final variant = product.variants.where((v) => v.id == variantId || v.label == item['variant_label']).toList();
        if (variant.isEmpty) continue;
        _lines.add(
          CartLine(
            id: '${product.id}_${variant.first.id}',
            product: product,
            variant: variant.first,
            unitPrice: (item['unit_price'] as num?)?.toDouble() ?? variant.first.price,
            quantity: (item['quantity'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      if (_lines.isNotEmpty && savedPricing == null) {
        _pricing = _localPricing();
      }
      notifyListeners();
    } catch (_) {
      await prefs.remove(key);
      _clearMemoryOnly();
    }
  }

  CartPricing _localPricing() {
    final subtotal = _lines.fold<double>(0, (sum, line) => sum + line.lineTotal);
    return CartPricing(
      subtotal: subtotal,
      voucherDiscount: 0,
      loyaltyDiscount: 0,
      deliveryFee: BranchController.instance.selectedBranch?.deliveryFee ?? 0,
      total: subtotal + (BranchController.instance.selectedBranch?.deliveryFee ?? 0),
      voucherCode: appliedVoucherCode,
      redeemPoints: redeemPoints,
      loyaltyPointsBalance: _pricing.loyaltyPointsBalance,
      loyaltyPointsUsed: 0,
    );
  }

  void _applyRemoteState(CartRemoteState remote) {
    _cartId = remote.cartId;
    appliedVoucherCode = remote.voucherCode;
    redeemPoints = remote.redeemPoints;
    _pricing = remote.pricing;
    _lines.clear();
    final previousLines = List<CartLine>.from(_lines);
    _lines.clear();
    for (final item in remote.items) {
      Product? product;
      try {
        product = findProductById(item.productId);
      } catch (_) {
        product = null;
      }
      if (product == null) {
        final cached = previousLines.where((line) => line.product.id == item.productId && line.variant.id == item.variantId).toList();
        if (cached.isNotEmpty) {
          final line = cached.first;
          line.quantity = item.quantity;
          line.unitPrice = item.currentPrice;
          _lines.add(line);
        }
        continue;
      }
      final matches = product.variants.where((v) => v.id == item.variantId || v.label == item.variantLabel).toList();
      if (matches.isEmpty) continue;
      final variant = matches.first;
      _lines.add(
        CartLine(
          id: '${product.id}_${variant.id}',
          product: product,
          variant: variant,
          unitPrice: item.currentPrice,
          quantity: item.quantity,
        ),
      );
    }
    _dirty = false;
    _revision++;
    lastError = null;
    notifyListeners();
  }

  Future<void> _saveLocalSnapshot({required bool dirty}) async {
    final key = _storageKey;
    if (key == null) return;
    final prefs = await _storage;
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
    await prefs.setString(key, jsonEncode(payload));
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
      lastError = _messageFor(e);
      _scheduleRetry();
      notifyListeners();
      return lastError;
    } finally {
      _syncing = false;
      notifyListeners();
    }
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
    final previous = appliedVoucherCode;
    appliedVoucherCode = normalized;
    _markDirty();
    final error = await _syncNow();
    if (error != null) {
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
      redeemPoints = previous;
      _dirty = true;
      _revision++;
      await _saveLocalSnapshot(dirty: true);
      notifyListeners();
      return error;
    }
    return null;
  }

  int addProduct(Product product, ProductVariant variant, {int quantity = 1, int? stockOverride}) {
    if (quantity <= 0) return 0;
    if (_firebaseUid == null) {
      lastError = 'Please sign in before adding items to your cart.';
      notifyListeners();
      return 0;
    }
    if (_branchId == null) {
      lastError = 'Please select a branch first.';
      notifyListeners();
      return 0;
    }
    final lineId = '${product.id}_${variant.id}';
    final index = _lines.indexWhere((line) => line.id == lineId);
    final currentQty = index == -1 ? 0 : _lines[index].quantity;
    final stock = stockOverride ?? variant.stockOnHand;
    var addable = quantity;
    if (stock != null) {
      final remaining = stock - currentQty;
      if (remaining <= 0) return 0;
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
    return addable;
  }

  Future<int> addProductWithLiveCheck(Product product, ProductVariant variant, {int quantity = 1}) async {
    if (!product.isActive) return 0;
    final branchId = BranchController.instance.selectedBranch?.id ?? _branchId;
    if (_firebaseUid != null && branchId == null) {
      lastError = 'Please select a branch first.';
      notifyListeners();
      return 0;
    }
    if (_branchId != branchId && _firebaseUid != null && branchId != null) {
      final switched = await switchBranch(branchId);
      if (!switched) return 0;
    }
    final liveStock = await ProductsRepository.instance.fetchLiveStock(
      productId: product.id,
      variantId: variant.id,
      branchId: branchId,
    );
    return addProduct(product, variant, quantity: quantity, stockOverride: liveStock);
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
    if (key != null) await (await _storage).remove(key);
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
    } catch (_) {
      return null;
    }
  }

  String _messageFor(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '').trim();
    return text.isEmpty ? 'Cart sync failed. We will retry when the connection is available.' : text;
  }
}

Future<void> addToCartWithFeedback(
  BuildContext context,
  Product product,
  ProductVariant variant, {
  int quantity = 1,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final added = await CartController.instance.addProductWithLiveCheck(product, variant, quantity: quantity);
  if (!context.mounted) return;
  if (added <= 0) {
    messenger.showSnackBar(
      SnackBar(content: Text(CartController.instance.lastError ?? 'This item is out of stock.')),
    );
    return;
  }
  final message = added < quantity
      ? 'Only $added available — added $added to cart.'
      : 'Added ${product.name} to cart';
  messenger.showSnackBar(
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
