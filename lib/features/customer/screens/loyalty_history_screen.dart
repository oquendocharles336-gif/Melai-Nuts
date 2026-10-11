import 'package:flutter/material.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/list_tools.dart';
import '../../../data/models/loyalty.dart';
import '../../../data/repositories/loyalty_repository.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Points history: searchable (order ID / description), filter earned or
/// redeemed, sort by date or points; read page by page from the server.
class LoyaltyHistoryScreen extends StatefulWidget {
  const LoyaltyHistoryScreen({super.key});

  @override
  State<LoyaltyHistoryScreen> createState() => _LoyaltyHistoryScreenState();
}

class _LoyaltyHistoryScreenState extends State<LoyaltyHistoryScreen> {
  static const _initial = ListQuery(sortId: 'newest');

  late final PagedListController<LoyaltyPointTransaction> _paged = PagedListController(
    query: _initial,
    fetch: (query, offset, limit) {
      final uid = AuthService.instance.currentFirebaseUser?.uid;
      if (uid == null) return Future.value(const PageResult<LoyaltyPointTransaction>([], 0));
      return LoyaltyRepository.instance.fetchTransactionsPage(uid, query, offset, limit);
    },
  );

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  List<SortOption<LoyaltyPointTransaction>> _sorts(AppLocalizations t) => [
        SortOption('newest', t.sortNewest, null),
        SortOption('oldest', t.sortOldest, null),
        SortOption('points', t.sortPointsHigh, null),
      ];

  List<FilterGroup<LoyaltyPointTransaction>> _groups(AppLocalizations t) => [
        FilterGroup('kind', t.filterType, [
          FilterChoice('earned', t.filterEarned, null),
          FilterChoice('redeemed', t.filterRedeemed, null),
        ]),
      ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Points History'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: _paged,
        builder: (context, _) {
          final query = _paged.query;
          return PagedListView<LoyaltyPointTransaction>(
            controller: _paged,
            emptyIcon: Icons.history_rounded,
            emptyTitle: 'No history yet.',
            emptyMessage: 'Your points activity will appear here.',
            onClearQuery: () => _paged.setQuery(_initial),
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSearchBar(
                  hint: t.searchHint,
                  initialValue: query.search,
                  onChanged: (text) => _paged.setQuery(query.copyWith(search: text)),
                  trailing: SortFilterButton(
                    active: query.hasFilters || query.sortId != _initial.sortId,
                    onPressed: () async {
                      final next = await SortFilterSheet.show<LoyaltyPointTransaction>(
                        context,
                        query: query,
                        sorts: _sorts(t),
                        groups: _groups(t),
                      );
                      if (next != null && mounted) _paged.setQuery(next);
                    },
                  ),
                ),
                ActiveFilterChips<LoyaltyPointTransaction>(
                  query: query,
                  groups: _groups(t),
                  onChanged: _paged.setQuery,
                ),
              ],
            ),
            itemBuilder: (context, tx) {
            final isEarn = tx.type == LoyaltyTransactionType.earn;

            return Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                border: Border.all(color: AppColors.border),
              ),
              child: Material(type: MaterialType.transparency, child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: isEarn ? AppColors.successBg : AppColors.errorBg,
                  child: Icon(
                    isEarn ? Icons.add : Icons.remove,
                    color: isEarn ? AppColors.success : AppColors.error,
                  ),
                ),
                title: Text(tx.description, style: AppTextStyles.titleMd),
                subtitle: Text(
                  '${tx.date.day}/${tx.date.month}/${tx.date.year} • ${tx.date.hour}:${tx.date.minute}'
                  '${tx.isRefundReversal ? ' • reversed because the order was refunded' : ''}',
                  style: AppTextStyles.bodySm,
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${isEarn ? '+' : '-'}${tx.points}',
                      style: AppTextStyles.labelLg.copyWith(
                        color: isEarn ? AppColors.success : AppColors.error,
                      ),
                    ),
                    Text(
                      'Points',
                      style: AppTextStyles.labelSm,
                    ),
                  ],
                ),
                onTap: () => Navigator.pushNamed(
                  context,
                  '/customer/loyalty/transaction',
                  arguments: tx,
                ),
              )),
            );
            },
          );
        },
      ),
    );
  }
}
