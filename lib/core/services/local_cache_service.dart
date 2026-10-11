import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One cached server response and when it was saved from a *live* fetch.
class CachedEntry {
  final String value;
  final DateTime savedAt;
  const CachedEntry(this.value, this.savedAt);
}

/// Durable, per-user store for the last successful server reads, so the
/// customer app can still show real (previously fetched) data after a cold
/// start with no connection.
///
/// What this is and is not:
///
///  * It is a *read* cache of data the server already gave this customer.
///    Nothing in it is ever authoritative and nothing here is a "pending
///    write" — those live in `PendingWritesService`.
///  * Entries are namespaced by a scope (the Firebase uid, or `anon` for
///    public catalog data) so one customer's data can never be served to
///    another account on a shared device. Scopes that don't belong to the
///    signed-in user are wiped ([keepOnly]) and a signed-out device holds
///    no customer data.
///  * Bounded: at most [_maxEntriesPerScope] entries per scope (oldest
///    evicted first) and no single entry above [_maxValueChars].
class LocalCache {
  LocalCache._();
  static final LocalCache instance = LocalCache._();

  static const int _maxEntriesPerScope = 600;
  static const int _maxValueChars = 1500000;
  static const String _scopesKey = 'melai_cache_scopes_v1';

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  final Map<String, List<String>> _indexes = {};
  Future<void> _tail = Future.value();

  /// Serialises all mutations so the per-scope index never races itself.
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  String _entryKey(String scope, String key) => 'melai_cache_v1|$scope|$key';
  String _indexKey(String scope) => 'melai_cache_index_v1|$scope';

  Future<List<String>> _readIndex(String scope) async {
    final cached = _indexes[scope];
    if (cached != null) return cached;
    final stored = await _prefs.getStringList(_indexKey(scope));
    final list = List<String>.from(stored ?? const <String>[]);
    _indexes[scope] = list;
    return list;
  }

  Future<void> put(String scope, String key, String value) {
    if (value.length > _maxValueChars) return Future.value();
    return _serial(() async {
      try {
        await _prefs.setString(
          _entryKey(scope, key),
          jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'v': value}),
        );
        final index = await _readIndex(scope);
        final isNewScope = index.isEmpty;
        index
          ..remove(key)
          ..add(key);
        while (index.length > _maxEntriesPerScope) {
          final evicted = index.removeAt(0);
          await _prefs.remove(_entryKey(scope, evicted));
        }
        await _prefs.setStringList(_indexKey(scope), index);
        if (isNewScope) await _rememberScope(scope);
      } catch (_) {
        // A full disk / unavailable storage must never break a live read.
      }
    });
  }

  Future<CachedEntry?> get(String scope, String key) async {
    try {
      final raw = await _prefs.getString(_entryKey(scope, key));
      if (raw == null) return null;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return CachedEntry(
        map['v'] as String,
        DateTime.fromMillisecondsSinceEpoch(map['t'] as int),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearScope(String scope) {
    return _serial(() async {
      try {
        final index = await _readIndex(scope);
        for (final key in List<String>.from(index)) {
          await _prefs.remove(_entryKey(scope, key));
        }
        await _prefs.remove(_indexKey(scope));
        _indexes.remove(scope);
        final scopes = await _prefs.getStringList(_scopesKey) ?? const <String>[];
        await _prefs.setStringList(
          _scopesKey,
          scopes.where((s) => s != scope).toList(),
        );
      } catch (_) {}
    });
  }

  /// Wipes every scope except [scopes]. Called whenever the signed-in
  /// account changes, so a previous customer's cached data can't outlive
  /// their session (including forced/expired sign-outs).
  Future<void> keepOnly(Set<String> scopes) async {
    try {
      final known = await _prefs.getStringList(_scopesKey) ?? const <String>[];
      for (final scope in known) {
        if (!scopes.contains(scope)) await clearScope(scope);
      }
    } catch (_) {}
  }

  Future<void> _rememberScope(String scope) async {
    final scopes = List<String>.from(await _prefs.getStringList(_scopesKey) ?? const <String>[]);
    if (!scopes.contains(scope)) {
      scopes.add(scope);
      await _prefs.setStringList(_scopesKey, scopes);
    }
  }
}
