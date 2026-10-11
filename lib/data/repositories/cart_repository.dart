import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';

class CartPricing {
  final double subtotal;
  final double voucherDiscount;
  final double loyaltyDiscount;
  final double deliveryFee;
  final double total;
  final String? voucherCode;
  final bool redeemPoints;
  final int loyaltyPointsBalance;
  final int loyaltyPointsUsed;

  const CartPricing({
    required this.subtotal,
    required this.voucherDiscount,
    required this.loyaltyDiscount,
    required this.deliveryFee,
    required this.total,
    required this.voucherCode,
    required this.redeemPoints,
    required this.loyaltyPointsBalance,
    required this.loyaltyPointsUsed,
  });

  Map<String, dynamic> toJson() {
    return {
      'subtotal': subtotal,
      'voucher_discount': voucherDiscount,
      'loyalty_discount': loyaltyDiscount,
      'delivery_fee': deliveryFee,
      'total': total,
      'voucher_code': voucherCode,
      'redeem_points': redeemPoints,
      'loyalty_points_balance': loyaltyPointsBalance,
      'loyalty_points_used': loyaltyPointsUsed,
    };
  }

  factory CartPricing.fromJson(Map<String, dynamic> json) {
    return CartPricing(
      subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
      voucherDiscount: (json['voucher_discount'] as num?)?.toDouble() ?? 0,
      loyaltyDiscount: (json['loyalty_discount'] as num?)?.toDouble() ?? 0,
      deliveryFee: (json['delivery_fee'] as num?)?.toDouble() ?? 0,
      total: (json['total'] as num?)?.toDouble() ?? 0,
      voucherCode: json['voucher_code'] as String?,
      redeemPoints: json['redeem_points'] as bool? ?? false,
      loyaltyPointsBalance: (json['loyalty_points_balance'] as num?)?.toInt() ?? 0,
      loyaltyPointsUsed: (json['loyalty_points_used'] as num?)?.toInt() ?? 0,
    );
  }
}

class CartRemoteItem {
  final String productId;
  final String variantId;
  final String variantLabel;
  final int quantity;
  final double currentPrice;

  const CartRemoteItem({
    required this.productId,
    required this.variantId,
    required this.variantLabel,
    required this.quantity,
    required this.currentPrice,
  });

  factory CartRemoteItem.fromJson(Map<String, dynamic> row) {
    return CartRemoteItem(
      productId: row['product_id'] as String,
      variantId: row['variant_id'] as String,
      variantLabel: row['variant_label'] as String,
      quantity: (row['quantity'] as num).toInt(),
      currentPrice: (row['current_price'] as num).toDouble(),
    );
  }
}

class CartRemoteState {
  final String cartId;
  final String branchId;
  final String? voucherCode;
  final bool redeemPoints;
  final List<CartRemoteItem> items;
  final CartPricing pricing;

  const CartRemoteState({
    required this.cartId,
    required this.branchId,
    required this.voucherCode,
    required this.redeemPoints,
    required this.items,
    required this.pricing,
  });

  factory CartRemoteState.fromJson(Map<String, dynamic> json) {
    final itemRows = (json['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => CartRemoteItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return CartRemoteState(
      cartId: json['cart_id'] as String,
      branchId: json['branch_id'] as String,
      voucherCode: json['voucher_code'] as String?,
      redeemPoints: json['redeem_points'] as bool? ?? false,
      items: itemRows,
      pricing: CartPricing.fromJson(
        Map<String, dynamic>.from((json['pricing'] as Map?) ?? const {}),
      ),
    );
  }
}

/// Every cart write goes through `sync_customer_cart` / `place_order`
/// (server-side). The customer roles are read-only on `carts`/`cart_items`,
/// so there is intentionally no direct-table write here (e.g. no `closeCart`;
/// `place_order` checks the cart out itself).
class CartRepository {
  CartRepository._();
  static final CartRepository instance = CartRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<CartRemoteState?> loadOpenCart({required String branchId}) async {
    final result = await _client.rpc(
      'get_customer_cart',
      params: {'p_branch_id': branchId},
    );
    if (result == null) return null;
    final map = Map<String, dynamic>.from(result as Map);
    if (map['cart_id'] == null) return null;
    return CartRemoteState.fromJson(map);
  }

  Future<CartRemoteState> syncCart({
    required String branchId,
    required List<Map<String, dynamic>> items,
    String? voucherCode,
    required bool redeemPoints,
  }) async {
    try {
      final result = await _client.rpc(
        'sync_customer_cart',
        params: {
          'p_branch_id': branchId,
          'p_items': items,
          'p_voucher_code': voucherCode,
          'p_redeem_points': redeemPoints,
        },
      );
      return CartRemoteState.fromJson(Map<String, dynamic>.from(result as Map));
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    }
  }


  Future<CartPricing> getPricing({required String cartId, required bool isDelivery}) async {
    try {
      final result = await _client.rpc(
        'get_cart_pricing',
        params: {'p_cart_id': cartId, 'p_is_delivery': isDelivery},
      );
      return CartPricing.fromJson(Map<String, dynamic>.from(result as Map));
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    }
  }
}
