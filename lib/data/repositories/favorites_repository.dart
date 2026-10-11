import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';

/// The signed-in customer's favourite products (migration 20261023000000:
/// `toggle_favorite`, `get_my_favorites`). Stored in the database, so they
/// follow the account to any phone. Only ids are kept here; the products
/// themselves come from the live catalogue.
class FavoritesRepository extends ChangeNotifier {
  FavoritesRepository({Future<Object?> Function(String fn, Map<String, dynamic>? params)? rpc}) : _rpcOverride = rpc;

  static final FavoritesRepository instance = FavoritesRepository();

  final Future<Object?> Function(String fn, Map<String, dynamic>? params)? _rpcOverride;
  SupabaseClient get _client => SupabaseService.instance.client;

  Future<Object?> _rpc(String fn, [Map<String, dynamic>? params]) =>
      _rpcOverride != null ? _rpcOverride(fn, params) : _client.rpc(fn, params: params);

  Set<String> _ids = <String>{};
  bool _loaded = false;
  AppError? lastError;

  bool get isLoaded => _loaded;
  Set<String> get ids => Set.unmodifiable(_ids);
  bool contains(String productId) => _ids.contains(productId);

  Future<void> load() async {
    try {
      final raw = await _rpc('get_my_favorites');
      _ids = {for (final v in (raw is List ? raw : const [])) '$v'};
      _loaded = true;
      lastError = null;
    } catch (e, st) {
      lastError = AppErrors.report(e, st, 'favorites:load');
    }
    notifyListeners();
  }

  /// Shows the change at once, then confirms with the server (which decides);
  /// on failure the heart goes back and [lastError] says why.
  Future<bool> toggle(String productId) async {
    final wasFavorite = _ids.contains(productId);
    wasFavorite ? _ids.remove(productId) : _ids.add(productId);
    notifyListeners();
    try {
      final now = await _rpc('toggle_favorite', {'p_product_id': productId});
      final isFavorite = now == true || now == 'true';
      isFavorite ? _ids.add(productId) : _ids.remove(productId);
      lastError = null;
      notifyListeners();
      return true;
    } catch (e, st) {
      wasFavorite ? _ids.add(productId) : _ids.remove(productId);
      lastError = AppErrors.report(e, st, 'favorites:toggle');
      notifyListeners();
      return false;
    }
  }

  /// Called on sign-out so the next account never sees these.
  void clear() {
    _ids = <String>{};
    _loaded = false;
    notifyListeners();
  }
}
