import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// FEFO (First Expired, First Out) urgency tier for a batch, derived from
/// how many days remain until its expiration date.
enum FefoPriority { high, medium, low }

extension FefoPriorityX on FefoPriority {
  String get label {
    switch (this) {
      case FefoPriority.high:
        return 'HIGH';
      case FefoPriority.medium:
        return 'MEDIUM';
      case FefoPriority.low:
        return 'LOW';
    }
  }

  String get description {
    switch (this) {
      case FefoPriority.high:
        return 'Sell within 15 days';
      case FefoPriority.medium:
        return 'Sell within 45 days';
      case FefoPriority.low:
        return 'Fresh batch, no urgency';
    }
  }

  Color get color {
    switch (this) {
      case FefoPriority.high:
        return AppColors.error;
      case FefoPriority.medium:
        return AppColors.warning;
      case FefoPriority.low:
        return AppColors.success;
    }
  }

  Color get background {
    switch (this) {
      case FefoPriority.high:
        return AppColors.errorBg;
      case FefoPriority.medium:
        return AppColors.warningBg;
      case FefoPriority.low:
        return AppColors.successBg;
    }
  }
}

/// One real inventory batch (`inventory_batches`): one product variant at one
/// branch, received on one date with its own expiry, tracked for FEFO
/// rotation and restock planning.
///
/// Low-stock is decided per VARIANT (all batches of that variant at the
/// branch together), not per batch: [variantStock] is the branch's total for
/// the variant and [restockThreshold] its restock level.
class InventoryBatch {
  final String id;
  final String productId;
  final String batchCode;
  final String branch;
  final DateTime receivedDate;
  final DateTime expirationDate;
  final int quantity;
  final int restockThreshold;

  final String branchId;
  final String variantId;
  final String variantLabel;

  /// Branch-wide stock of this batch's variant. Defaults to [quantity].
  final int? variantStock;

  const InventoryBatch({
    required this.id,
    required this.productId,
    required this.batchCode,
    required this.branch,
    required this.receivedDate,
    required this.expirationDate,
    required this.quantity,
    this.restockThreshold = 20,
    this.branchId = '',
    this.variantId = '',
    this.variantLabel = '',
    this.variantStock,
  });

  factory InventoryBatch.fromJson(
    Map<String, dynamic> j, {
    required String variantLabel,
    required int restockThreshold,
    required int variantStock,
  }) {
    return InventoryBatch(
      id: j['id'] as String,
      productId: j['product_id'] as String,
      batchCode: (j['batch_code'] as String?) ?? '',
      branch: (j['branch_name'] as String?) ?? '',
      receivedDate: DateTime.parse(j['received_date'] as String),
      expirationDate: DateTime.parse(j['expiration_date'] as String),
      quantity: (j['quantity'] as num).toInt(),
      restockThreshold: restockThreshold,
      branchId: j['branch_id'] as String,
      variantId: j['variant_id'] as String,
      variantLabel: variantLabel,
      variantStock: variantStock,
    );
  }

  /// Whole calendar days until expiry (expiry dates carry no time of day).
  int get daysUntilExpiry {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final exp = DateTime(expirationDate.year, expirationDate.month, expirationDate.day);
    return exp.difference(today).inDays;
  }

  FefoPriority get fefoPriority {
    final days = daysUntilExpiry;
    if (days <= 15) return FefoPriority.high;
    if (days <= 45) return FefoPriority.medium;
    return FefoPriority.low;
  }

  int get _stock => variantStock ?? quantity;

  bool get isLowStock => _stock <= restockThreshold;

  /// A simple "top up to 2x threshold" restock suggestion.
  int get recommendedRestockQty =>
      isLowStock ? (restockThreshold * 2 - _stock).clamp(0, 999999) : 0;
}
