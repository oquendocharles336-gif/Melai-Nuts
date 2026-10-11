import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_error.dart';
import '../utils/format_utils.dart';
import '../utils/validation_utils.dart';
import 'state_views.dart';

// =============================================================================
// Search, sort and filter — one set of widgets for every list in the app.
// =============================================================================

/// The search box used on every list: debounced (350 ms), with a clear
/// button, a 100-character limit and an optional result count.
class AppSearchBar extends StatefulWidget {
  const AppSearchBar({
    super.key,
    required this.onChanged,
    this.hint,
    this.initialValue = '',
    this.debounce = const Duration(milliseconds: 350),
    this.trailing,
    this.autofocus = false,
  });

  /// Called with the trimmed text once typing pauses (and at once on clear).
  final ValueChanged<String> onChanged;
  final String? hint;
  final String initialValue;
  final Duration debounce;

  /// E.g. the sort / filter button.
  final Widget? trailing;
  final bool autofocus;

  @override
  State<AppSearchBar> createState() => _AppSearchBarState();
}

class _AppSearchBarState extends State<AppSearchBar> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String value) {
    setState(() {}); // show / hide the clear button
    _timer?.cancel();
    _timer = Timer(widget.debounce, () {
      if (mounted) widget.onChanged(value.trim());
    });
  }

  void _clear() {
    _timer?.cancel();
    _controller.clear();
    setState(() {});
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            autofocus: widget.autofocus,
            onChanged: _changed,
            onSubmitted: (v) {
              _timer?.cancel();
              widget.onChanged(v.trim());
            },
            textInputAction: TextInputAction.search,
            maxLength: InputLimits.search,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            decoration: InputDecoration(
              counterText: '',
              hintText: widget.hint ?? t.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t.clearSearch,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _clear,
                    ),
            ),
          ),
        ),
        if (widget.trailing != null) ...[
          const SizedBox(width: AppSpacing.xs),
          widget.trailing!,
        ],
      ],
    );
  }
}

/// One way to sort a list.
class SortOption<T> {
  const SortOption(this.id, this.label, this.compare);
  final String id;
  final String label;

  /// Used for lists sorted on the device; server-sorted lists may pass null.
  final int Function(T a, T b)? compare;
}

/// One filter value ("Pending").
class FilterChoice<T> {
  const FilterChoice(this.id, this.label, this.test);
  final String id;
  final String label;

  /// Used for lists filtered on the device; server-filtered lists may pass null.
  final bool Function(T item)? test;
}

/// A group of mutually exclusive filter values ("Status": Pending / Approved…).
/// No value chosen = no filter.
class FilterGroup<T> {
  const FilterGroup(this.id, this.label, this.choices);
  final String id;
  final String label;
  final List<FilterChoice<T>> choices;
}

/// The current search text, sort and filters of a list.
class ListQuery {
  const ListQuery({this.search = '', required this.sortId, this.filters = const {}});

  final String search;
  final String sortId;

  /// group id -> choice id.
  final Map<String, String> filters;

  bool get hasFilters => filters.isNotEmpty;
  bool get isNarrowed => search.isNotEmpty || filters.isNotEmpty;

  ListQuery copyWith({String? search, String? sortId, Map<String, String>? filters}) => ListQuery(
        search: search ?? this.search,
        sortId: sortId ?? this.sortId,
        filters: filters ?? this.filters,
      );

  ListQuery without(String groupId) => copyWith(filters: {...filters}..remove(groupId));
}

/// Applies [query] to an in-memory list: every search word must appear in
/// [text] (case-insensitive), every chosen filter must pass, then the chosen
/// sort. Used by lists whose records are all on the device (staff stores,
/// saved addresses…); server-paged lists send the same query to the server.
List<T> applyListQuery<T>(
  Iterable<T> items,
  ListQuery query, {
  required String Function(T item) text,
  required List<SortOption<T>> sorts,
  List<FilterGroup<T>> groups = const [],
}) {
  final words = query.search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final tests = <bool Function(T)>[
    for (final g in groups)
      if (query.filters[g.id] != null)
        for (final c in g.choices)
          if (c.id == query.filters[g.id] && c.test != null) c.test!,
  ];
  final out = items.where((item) {
    if (words.isNotEmpty) {
      final hay = text(item).toLowerCase();
      if (!words.every(hay.contains)) return false;
    }
    return tests.every((test) => test(item));
  }).toList();
  final sort = sorts.where((s) => s.id == query.sortId).firstOrNull ?? (sorts.isEmpty ? null : sorts.first);
  final compare = sort?.compare;
  if (compare != null) out.sort(compare);
  return out;
}

/// Bottom sheet to choose the sort and filters. Returns the new query, or
/// null when closed without applying.
class SortFilterSheet<T> extends StatefulWidget {
  const SortFilterSheet({super.key, required this.query, required this.sorts, required this.groups});

  final ListQuery query;
  final List<SortOption<T>> sorts;
  final List<FilterGroup<T>> groups;

  static Future<ListQuery?> show<T>(
    BuildContext context, {
    required ListQuery query,
    required List<SortOption<T>> sorts,
    List<FilterGroup<T>> groups = const [],
  }) {
    return showModalBottomSheet<ListQuery>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SortFilterSheet<T>(query: query, sorts: sorts, groups: groups),
    );
  }

  @override
  State<SortFilterSheet<T>> createState() => _SortFilterSheetState<T>();
}

class _SortFilterSheetState<T> extends State<SortFilterSheet<T>> {
  late String _sort = widget.query.sortId;
  late final Map<String, String> _filters = {...widget.query.filters};

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
          children: [
            Text(t.sortAndFilter, style: AppTextStyles.headlineSm),
            const SizedBox(height: AppSpacing.md),
            if (widget.sorts.length > 1) ...[
              Text(t.sortBy, style: AppTextStyles.labelLg),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final s in widget.sorts)
                    ChoiceChip(
                      label: Text(s.label),
                      selected: _sort == s.id,
                      onSelected: (_) => setState(() => _sort = s.id),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            for (final g in widget.groups) ...[
              Text(g.label, style: AppTextStyles.labelLg),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  ChoiceChip(
                    label: Text(t.filterAll),
                    selected: _filters[g.id] == null,
                    onSelected: (_) => setState(() => _filters.remove(g.id)),
                  ),
                  for (final c in g.choices)
                    ChoiceChip(
                      label: Text(c.label),
                      selected: _filters[g.id] == c.id,
                      onSelected: (_) => setState(() => _filters[g.id] = c.id),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => setState(() {
                      _filters.clear();
                      if (widget.sorts.isNotEmpty) _sort = widget.sorts.first.id;
                    }),
                    child: Text(t.reset),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.of(context).pop(
                      widget.query.copyWith(sortId: _sort, filters: Map.of(_filters)),
                    ),
                    child: Text(t.apply),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Sort & filter" icon button, with a dot when filters are active.
class SortFilterButton extends StatelessWidget {
  const SortFilterButton({super.key, required this.onPressed, this.active = false});

  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: AppLocalizations.of(context).sortAndFilter,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: onPressed,
      icon: Badge(isLabelVisible: active, smallSize: 8, child: const Icon(Icons.tune_rounded)),
    );
  }
}

/// The active filters as removable chips, plus "Clear all".
class ActiveFilterChips<T> extends StatelessWidget {
  const ActiveFilterChips({super.key, required this.query, required this.groups, required this.onChanged});

  final ListQuery query;
  final List<FilterGroup<T>> groups;
  final ValueChanged<ListQuery> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!query.hasFilters) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final chips = <Widget>[];
    for (final g in groups) {
      final chosen = query.filters[g.id];
      if (chosen == null) continue;
      final label = g.choices.where((c) => c.id == chosen).map((c) => c.label).firstOrNull ?? chosen;
      chips.add(InputChip(
        label: Text('${g.label}: $label'),
        onDeleted: () => onChanged(query.without(g.id)),
        deleteButtonTooltipMessage: t.clearFilters,
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            onPressed: () => onChanged(query.copyWith(filters: const {})),
            child: Text(t.clearAll),
          ),
        ],
      ),
    );
  }
}

/// "No results for '…'" with a "Clear filters" action.
class NoResultsView extends StatelessWidget {
  const NoResultsView({super.key, required this.query, required this.onClear, this.compact = false});

  final ListQuery query;
  final VoidCallback onClear;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StateEmptyView(
      compact: compact,
      icon: Icons.search_off_rounded,
      title: query.search.isEmpty ? t.noMatchingFilters : t.noResultsFor(query.search),
      message: t.noResultsMessage,
      actionLabel: t.clearFilters,
      onAction: onClear,
    );
  }
}

/// Shows "Saved data · last updated …" when a list is shown from the local
/// database instead of a live answer.
class LastUpdatedBanner extends StatelessWidget {
  const LastUpdatedBanner({super.key, required this.savedAt});

  final DateTime? savedAt;

  @override
  Widget build(BuildContext context) {
    final at = savedAt;
    if (at == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              AppLocalizations.of(context).lastUpdated(friendlyTime(at)),
              style: AppTextStyles.bodySm.copyWith(color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Paging: load 25 at a time, the next page near the end of the list.
// =============================================================================

/// One page from the server: the rows and how many match in total.
class PageResult<T> {
  const PageResult(this.items, this.total);
  final List<T> items;
  final int total;
}

/// Loads a list page by page for [PagedListView]. Every new [query] starts
/// again from the first page; answers that arrive for an older query are
/// ignored (so typing fast never shows stale results).
class PagedListController<T> extends ChangeNotifier {
  PagedListController({
    required this.fetch,
    required ListQuery query,
    this.pageSize = 25,
    this.timeout = const Duration(seconds: 20),
    // A public `query:` argument for a private, mutable field (changed by setQuery).
    // ignore: prefer_initializing_formals
  }) : _query = query;

  /// Loads `limit` items starting at `offset` for `query`.
  final Future<PageResult<T>> Function(ListQuery query, int offset, int limit) fetch;
  final int pageSize;
  final Duration timeout;

  ListQuery _query;
  ListQuery get query => _query;

  final List<T> items = [];
  int total = 0;
  bool loading = false;
  bool loadingMore = false;
  AppError? error;
  bool _started = false;
  int _token = 0;
  bool _disposed = false;

  bool get hasMore => items.length < total;
  bool get isEmpty => _started && !loading && error == null && items.isEmpty;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// First page (again). Keeps what is on screen until the answer arrives.
  Future<void> refresh() async {
    final token = ++_token;
    _started = true;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await fetch(_query, 0, pageSize).timeout(timeout);
      if (token != _token) return;
      items
        ..clear()
        ..addAll(page.items);
      total = page.total;
    } catch (e, st) {
      if (token != _token) return;
      error = AppErrors.report(e, st, 'paged_list:refresh');
    } finally {
      if (token == _token) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore || error != null) return;
    final token = _token;
    loadingMore = true;
    _notify();
    try {
      final page = await fetch(_query, items.length, pageSize).timeout(timeout);
      if (token != _token) return;
      items.addAll(page.items);
      total = page.total;
    } catch (e, st) {
      if (token != _token) return;
      error = AppErrors.report(e, st, 'paged_list:loadMore');
    } finally {
      if (token == _token) {
        loadingMore = false;
        _notify();
      }
    }
  }

  void setQuery(ListQuery query) {
    _query = query;
    refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    super.dispose();
  }
}

/// A lazily built list (ListView.builder) for a [PagedListController]:
/// pull-to-refresh, infinite scroll with a bottom loader, an "end of list"
/// line, and the loading / error (Retry) / empty / no-results states.
class PagedListView<T> extends StatefulWidget {
  const PagedListView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    required this.emptyTitle,
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
    this.header,
    this.onClearQuery,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.separator = const SizedBox(height: AppSpacing.sm),
    this.errorScope = ErrorScope.general,
  });

  final PagedListController<T> controller;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;

  /// Search bar, chips… scrolled with the list.
  final Widget? header;

  /// Shown as "Clear filters" when a search / filter finds nothing.
  final VoidCallback? onClearQuery;
  final EdgeInsets padding;
  final Widget separator;
  final ErrorScope errorScope;

  @override
  State<PagedListView<T>> createState() => _PagedListViewState<T>();
}

class _PagedListViewState<T> extends State<PagedListView<T>> {
  @override
  void initState() {
    super.initState();
    if (!widget.controller.loading && widget.controller.items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.refresh();
      });
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.extentAfter < 400) widget.controller.loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final header = widget.header;
        Widget? state;
        if (c.items.isEmpty) {
          if (c.loading || !c.isEmpty && c.error == null) {
            state = const StateLoadingView(compact: true);
          } else if (c.error != null) {
            state = StateErrorView(error: c.error, scope: widget.errorScope, onRetry: c.refresh, compact: true);
          } else if (c.query.isNarrowed && widget.onClearQuery != null) {
            state = NoResultsView(query: c.query, onClear: widget.onClearQuery!, compact: true);
          } else {
            state = StateEmptyView(
              icon: widget.emptyIcon,
              title: widget.emptyTitle,
              message: widget.emptyMessage,
              compact: true,
            );
          }
        }
        final extra = header == null ? 0 : 1;
        // header, items…, footer (loader / error / end of list)
        final count = extra + (state != null ? 1 : c.items.length + 1);
        return RefreshIndicator(
          onRefresh: c.refresh,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: widget.padding,
              itemCount: count,
              separatorBuilder: (_, i) => i < extra ? const SizedBox(height: AppSpacing.sm) : widget.separator,
              itemBuilder: (context, i) {
                if (header != null && i == 0) return header;
                final index = i - extra;
                if (state != null) {
                  return Padding(padding: const EdgeInsets.only(top: AppSpacing.lg), child: state);
                }
                if (index < c.items.length) return widget.itemBuilder(context, c.items[index]);
                // Footer.
                if (c.loadingMore) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Center(
                      child: Semantics(label: t.loadingMore, child: const CircularProgressIndicator()),
                    ),
                  );
                }
                if (c.error != null) {
                  return Center(
                    child: TextButton.icon(
                      onPressed: () {
                        c.error = null;
                        c.loadMore();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry),
                    ),
                  );
                }
                if (!c.hasMore) {
                  return Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(t.endOfList, textAlign: TextAlign.center, style: AppTextStyles.bodySm),
                  );
                }
                return const SizedBox(height: 48);
              },
            ),
          ),
        );
      },
    );
  }
}
