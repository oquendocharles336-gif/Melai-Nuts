import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connectivity_service.dart';
import 'local_cache_service.dart';

/// Tracks which server resources (tables / read RPCs) the app is currently
/// showing from the local cache instead of a live response.
///
/// A resource is marked *stale* when a read was answered from the cache
/// (offline, timeout, or server 5xx) and is cleared the moment a live
/// response for it succeeds. UI uses this to label saved data honestly —
/// cached data is never presented as current.
class CacheStatus extends ChangeNotifier {
  CacheStatus._();
  static final CacheStatus instance = CacheStatus._();

  final Map<String, DateTime> _stale = {};
  int _serveCounter = 0;

  /// Total number of reads ever answered from the cache (monotonic). Used to
  /// tell whether a refresh cycle was fully live.
  int get serveCounter => _serveCounter;

  bool get isShowingSavedData => _stale.isNotEmpty;

  /// When the *oldest* currently-displayed cached response was fetched live.
  DateTime? get oldestSavedAt {
    DateTime? oldest;
    for (final t in _stale.values) {
      if (oldest == null || t.isBefore(oldest)) oldest = t;
    }
    return oldest;
  }

  void markServed(String resource, DateTime savedAt) {
    _serveCounter++;
    final previous = _stale[resource];
    // Keep the older timestamp: the label must reflect the stalest data shown.
    if (previous == null || savedAt.isBefore(previous)) {
      _stale[resource] = savedAt;
    }
    notifyListeners();
  }

  void markLive(String resource) {
    if (_stale.remove(resource) != null) notifyListeners();
  }

  void reset() {
    if (_stale.isEmpty) return;
    _stale.clear();
    notifyListeners();
  }
}

/// `http.Client` handed to `Supabase.initialize`. It adds a durable
/// read-through cache in front of PostgREST **reads only**:
///
///  * `GET /rest/v1/...` and a small allow-list of read-only RPCs are cached
///    on every successful live response.
///  * When a read cannot be answered live — the device is known offline, the
///    request times out / fails, or the server answers 5xx — the last live
///    response for the same request (same signed-in user) is served instead,
///    and [CacheStatus] records that the data is stale.
///  * If there is no cached copy the original error propagates unchanged, so
///    nothing is ever fabricated.
///  * Writes (POST/PATCH/DELETE) and every mutating RPC (`place_order`,
///    `redeem_reward`, `request_refund`, cart sync, ...) pass straight
///    through untouched: they are never cached, never replayed, and never
///    reported as successful by this layer.
class OfflineReadCacheClient extends http.BaseClient {
  OfflineReadCacheClient({http.Client? inner}) : _inner = inner ?? http.Client();

  final http.Client _inner;

  static const Duration _readTimeout = Duration(seconds: 15);
  static const String _restPrefix = '/rest/v1/';

  /// Read-only RPCs that are safe to cache. Mutating RPCs must never be here.
  static const Set<String> _cacheableRpcs = {'get_popular_products'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resource = _cacheableResource(request);
    if (resource == null) return _inner.send(request);

    final scope = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
    final key = _cacheKey(request);

    // Known offline: answer from the cache immediately instead of waiting
    // for a doomed request. With no cached copy, still try the network —
    // the connectivity signal is a hint, not proof.
    if (!ConnectivityService.instance.isOnline) {
      final hit = await LocalCache.instance.get(scope, key);
      if (hit != null) return _serve(request, resource, hit);
    }

    http.StreamedResponse response;
    List<int> bytes;
    try {
      response = await _inner.send(request).timeout(_readTimeout);
      bytes = await response.stream.toBytes().timeout(_readTimeout);
    } catch (_) {
      final hit = await LocalCache.instance.get(scope, key);
      if (hit != null) return _serve(request, resource, hit);
      rethrow;
    }

    final status = response.statusCode;
    if (status == 200 || status == 206) {
      CacheStatus.instance.markLive(resource);
      // Don't write another account's data under the wrong scope if the
      // session changed while this request was in flight.
      final currentScope = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
      if (currentScope == scope) {
        unawaited(LocalCache.instance.put(scope, key, _pack(response, bytes)));
      }
    } else if (status >= 500) {
      final hit = await LocalCache.instance.get(scope, key);
      if (hit != null) return _serve(request, resource, hit);
    }

    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      status,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// Returns the table / RPC name if [request] is a cacheable read, else null.
  String? _cacheableResource(http.BaseRequest request) {
    final path = request.url.path;
    final index = path.indexOf(_restPrefix);
    if (index < 0) return null;
    final rest = path.substring(index + _restPrefix.length);
    if (request.method == 'GET') {
      if (rest.startsWith('rpc/')) return null;
      final name = rest.split('/').first;
      return name.isEmpty ? null : name;
    }
    if (request.method == 'POST' && rest.startsWith('rpc/')) {
      final name = rest.substring(4).split('/').first;
      return _cacheableRpcs.contains(name) ? 'rpc:$name' : null;
    }
    return null;
  }

  String _cacheKey(http.BaseRequest request) {
    final accept = request.headers['Accept'] ?? request.headers['accept'] ?? '';
    final range = request.headers['Range'] ?? request.headers['range'] ?? '';
    final body = request is http.Request ? request.body : '';
    return '${request.method}|${request.url}|$accept|$range|$body';
  }

  String _pack(http.StreamedResponse response, List<int> bytes) {
    return jsonEncode({
      'ct': response.headers['content-type'],
      'cr': response.headers['content-range'],
      'b': utf8.decode(bytes, allowMalformed: true),
    });
  }

  http.StreamedResponse _serve(
    http.BaseRequest request,
    String resource,
    CachedEntry entry,
  ) {
    final stored = Map<String, dynamic>.from(jsonDecode(entry.value) as Map);
    final bytes = utf8.encode(stored['b'] as String);
    CacheStatus.instance.markServed(resource, entry.savedAt);
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      200,
      contentLength: bytes.length,
      request: request,
      reasonPhrase: 'OK',
      headers: {
        'content-type': (stored['ct'] as String?) ?? 'application/json; charset=utf-8',
        if (stored['cr'] != null) 'content-range': stored['cr'] as String,
        'x-melai-served-from-cache': 'true',
      },
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
