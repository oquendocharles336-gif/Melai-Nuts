import 'package:flutter/material.dart';
import '../../../app/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/list_tools.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../core/widgets/staff_data_scope.dart';
import '../../../core/widgets/state_views.dart';
import '../../../data/models/inventory_item.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../widgets/inventory_card.dart';

/// Every product variant stocked at the branch, with real quantities. Tap
/// through to see the batches (FEFO order) that make up the stock.
///
/// Search (name, size, SKU), sort (name, quantity) and filter (stock level).
/// The branch's stock rows are already loaded by the staff store, so the
/// query runs on the device; the list itself is built lazily.
class InventoryListScreen extends StatefulWidget {
  const InventoryListScreen({super.key});

  @override
  State<InventoryListScreen> createState() => _InventoryListScreenState();
}

class _InventoryListScreenState extends State<InventoryListScreen> {
  static const _initial = ListQuery(sortId: 'name');
  ListQuery _query = _initial;

  List<SortOption<InventoryItem>> _sorts(AppLocalizations t) => [
        SortOption('name', t.sortAZ, (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase())),
        SortOption('nameDesc', t.sortZA, (a, b) => b.displayName.toLowerCase().compareTo(a.displayName.toLowerCase())),
        SortOption('qtyLow', t.sortQuantityLow, (a, b) => a.quantity.compareTo(b.quantity)),
        SortOption('qtyHigh', t.sortQuantityHigh, (a, b) => b.quantity.compareTo(a.quantity)),
      ];

  List<FilterGroup<InventoryItem>> _groups(AppLocalizations t) => [
        FilterGroup('stock', t.filterStock, [
          FilterChoice('out', t.stockOut, (i) => i.isOutOfStock),
          FilterChoice('low', t.stockLow, (i) => i.isLowStock && !i.isOutOfStock),
          FilterChoice('normal', t.stockNormal, (i) => !i.needsRestock),
        ]),
      ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StaffDataScope(
      builder: (context, store) {
        final all = store.inventoryItems;
        final groups = _groups(t);
        final items = applyListQuery<InventoryItem>(
          all,
          _query,
          text: (i) => '${i.productName} ${i.variantLabel} ${i.sku}',
          sorts: _sorts(t),
          groups: groups,
        );
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: MelaiAppBar(
            title: store.activeBranchName.isEmpty ? 'Inventory List' : 'Inventory • ${store.activeBranchName}',
            showBack: true,
          ),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: store.refreshInventory,
              child: DataStateView(
                isLoading: store.inventoryState.busy,
                error: store.inventoryState.error,
                isEmpty: all.isEmpty,
                onRetry: store.refreshInventory,
                emptyIcon: Icons.inventory_2_outlined,
                emptyTitle: 'No products yet.',
                emptyMessage: 'Add products under Products, then record the real count with Receive Stock.',
                builder: (context) => ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  // Row 0 = search + filters; then the items (or "no results").
                  itemCount: 1 + (items.isEmpty ? 1 : items.length),
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppSearchBar(
                            hint: t.searchHint,
                            initialValue: _query.search,
                            onChanged: (text) => setState(() => _query = _query.copyWith(search: text)),
                            trailing: SortFilterButton(
                              active: _query.hasFilters || _query.sortId != _initial.sortId,
                              onPressed: () async {
                                final next = await SortFilterSheet.show<InventoryItem>(
                                  context,
                                  query: _query,
                                  sorts: _sorts(t),
                                  groups: groups,
                                );
                                if (next != null && mounted) setState(() => _query = next);
                              },
                            ),
                          ),
                          ActiveFilterChips<InventoryItem>(
                            query: _query,
                            groups: groups,
                            onChanged: (q) => setState(() => _query = q),
                          ),
                        ],
                      );
                    }
                    if (items.isEmpty) {
                      return NoResultsView(
                        query: _query,
                        onClear: () => setState(() => _query = _initial),
                        compact: true,
                      );
                    }
                    final item = items[i - 1];
                    return InventoryCard.item(
                      item: item,
                      onTap: () => Navigator.of(context)
                          .pushNamed(AppRoutes.inventoryProductDetails, arguments: item.variantId),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
