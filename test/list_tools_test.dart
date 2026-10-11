import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/app/routes.dart';
import 'package:melai_nuts/core/services/legal_service.dart';
import 'package:melai_nuts/core/utils/format_utils.dart';
import 'package:melai_nuts/core/widgets/list_tools.dart';
import 'package:melai_nuts/data/models/user_role.dart';
import 'package:melai_nuts/l10n/generated/app_localizations.dart';

class _Row {
  const _Row(this.name, this.qty, this.active);
  final String name;
  final int qty;
  final bool active;
}

const _rows = [
  _Row('Roasted Kasoy', 5, true),
  _Row('Garlic Mani', 0, true),
  _Row('Kasoy Brittle', 20, false),
];

final _sorts = <SortOption<_Row>>[
  SortOption('az', 'A–Z', (a, b) => a.name.compareTo(b.name)),
  SortOption('qty', 'Quantity', (a, b) => a.qty.compareTo(b.qty)),
];

final _groups = <FilterGroup<_Row>>[
  FilterGroup('state', 'State', [
    FilterChoice('active', 'Active', (r) => r.active),
    FilterChoice('inactive', 'Inactive', (r) => !r.active),
  ]),
];

List<String> _names(ListQuery q) =>
    applyListQuery<_Row>(_rows, q, text: (r) => r.name, sorts: _sorts, groups: _groups).map((r) => r.name).toList();

void main() {
  group('applyListQuery', () {
    test('search is case-insensitive and needs every word', () {
      expect(_names(const ListQuery(sortId: 'az', search: 'KASOY')), ['Kasoy Brittle', 'Roasted Kasoy']);
      expect(_names(const ListQuery(sortId: 'az', search: 'kasoy roasted')), ['Roasted Kasoy']);
      expect(_names(const ListQuery(sortId: 'az', search: 'cashew')), isEmpty);
    });

    test('filters and sort combine', () {
      expect(_names(const ListQuery(sortId: 'qty', filters: {'state': 'active'})), ['Garlic Mani', 'Roasted Kasoy']);
      expect(_names(const ListQuery(sortId: 'az', filters: {'state': 'inactive'})), ['Kasoy Brittle']);
    });

    test('an unknown sort falls back to the first one', () {
      expect(_names(const ListQuery(sortId: 'nope')), ['Garlic Mani', 'Kasoy Brittle', 'Roasted Kasoy']);
    });

    test('ListQuery helpers', () {
      const q = ListQuery(sortId: 'az', search: 'x', filters: {'state': 'active'});
      expect(q.isNarrowed, isTrue);
      expect(q.without('state').hasFilters, isFalse);
      expect(const ListQuery(sortId: 'az').isNarrowed, isFalse);
    });
  });

  group('PagedListController', () {
    test('loads pages, stops at the total, and ignores answers for an old query', () async {
      final calls = <String>[];
      final c = PagedListController<int>(
        pageSize: 10,
        query: const ListQuery(sortId: 'n'),
        fetch: (q, offset, limit) async {
          calls.add('${q.search}@$offset');
          final all = List.generate(q.search.isEmpty ? 25 : 3, (i) => i);
          return PageResult(all.skip(offset).take(limit).toList(), all.length);
        },
      );
      await c.refresh();
      expect(c.items, hasLength(10));
      expect(c.hasMore, isTrue);
      await c.loadMore();
      await c.loadMore();
      expect(c.items, hasLength(25));
      expect(c.hasMore, isFalse);
      await c.loadMore(); // nothing more to load
      expect(calls, ['@0', '@10', '@20']);

      c.setQuery(const ListQuery(sortId: 'n', search: 'k'));
      await Future<void>.delayed(Duration.zero);
      expect(c.items, hasLength(3));
      expect(c.total, 3);
      c.dispose();
    });

    test('a failed page keeps an error for Retry instead of crashing', () async {
      final c = PagedListController<int>(
        query: const ListQuery(sortId: 'n'),
        fetch: (q, offset, limit) async => throw StateError('offline'),
      );
      await c.refresh();
      expect(c.error, isNotNull);
      expect(c.items, isEmpty);
      c.dispose();
    });
  });

  testWidgets('AppSearchBar debounces typing', (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: AppSearchBar(onChanged: seen.add)),
    ));
    await tester.enterText(find.byType(TextField), 'kas');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'kasoy');
    expect(seen, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(seen, ['kasoy']);
  });

  test('phones are masked on profile screens', () {
    expect(maskPhone('+639171234567'), '0917 *** 4567');
    expect(maskPhone(''), '');
    expect(maskPhone(null), '');
  });

  test('legal re-acceptance is needed only when the version changes', () {
    expect(LegalService.needsAcceptance(null), isTrue);
    expect(LegalService.needsAcceptance('old|old'), isTrue);
    expect(LegalService.needsAcceptance(LegalService.currentVersion), isFalse);
  });

  test('Terms and Privacy are readable before signing in', () {
    expect(AppRoutes.canOpen(AppRoutes.legalTerms, null, signedIn: false), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.legalPrivacy, null, signedIn: false), isTrue);
    expect(AppRoutes.canOpen(AppRoutes.appPermissions, null, signedIn: false), isFalse);
    expect(AppRoutes.canOpen(AppRoutes.appPermissions, UserRole.customer), isTrue);
  });
}
