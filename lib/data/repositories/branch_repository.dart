import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../catalog_store.dart';
import '../models/branch.dart';

/// Loads the real branch list (`branches` table) into [kBranches].
///
/// Branches are public read data (any signed-in or guest customer needs to
/// see them to pick one), same as the product catalog.
///
/// A [ChangeNotifier] that reports the real load status ([isLoading],
/// [error], [hasLoaded]) so the branch picker can show a spinner, an error
/// with a retry button, or a genuine "no branches" state.
class BranchRepository extends ChangeNotifier {
  BranchRepository._();
  static final BranchRepository instance = BranchRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  Future<void>? _inFlight;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  AppError? _error;

  /// Customer-safe error from the last failed load; null after a success.
  AppError? get error => _error;

  bool _hasLoaded = false;

  /// True once branches have loaded successfully at least once.
  bool get hasLoaded => _hasLoaded;

  /// Fetches every branch and refreshes [kBranches] in place. Safe to call
  /// repeatedly (e.g. pull-to-refresh on the branch picker); concurrent
  /// calls share one in-flight request. Never throws — check [error].
  Future<void> loadBranches() => _inFlight ??= _run();

  Future<void> _run() async {
    _isLoading = true;
    // Deferred so it is safe to call from initState (mid-build).
    scheduleMicrotask(notifyListeners);
    try {
      final raw = await AppErrors.guard(
        () => _client.from('branches').select().order('name'),
      );
      final branches = List<Map<String, dynamic>>.from(raw).map(Branch.fromRow).toList();
      kBranches
        ..clear()
        ..addAll(branches);
      _error = null;
      _hasLoaded = true;
    } catch (e) {
      // Keep the last loaded branches; report the failure for the UI.
      _error = AppErrors.from(e);
    } finally {
      _isLoading = false;
      _inFlight = null;
      notifyListeners();
    }
  }

  Branch? findById(String id) {
    for (final b in kBranches) {
      if (b.id == id) return b;
    }
    return null;
  }
}
