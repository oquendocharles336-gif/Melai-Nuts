import '../../../data/models/inventory_item.dart';

/// The register's item whose SKU (`product_variants.sku`) equals [code]
/// (a scanned barcode or a typed code), ignoring case and surrounding spaces.
/// Null when nothing matches — never a "closest" guess.
InventoryItem? matchSku(Iterable<InventoryItem> items, String code) {
  final wanted = code.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  for (final item in items) {
    if (item.sku.isNotEmpty && item.sku.trim().toLowerCase() == wanted) return item;
  }
  return null;
}
