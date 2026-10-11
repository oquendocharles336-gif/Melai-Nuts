import 'package:flutter/material.dart';

import '../services/staff_store.dart';
import '../theme/app_colors.dart';
import 'state_views.dart';

/// Wraps a staff screen so it (1) makes sure the staff session is loaded, even
/// when the screen is opened directly (deep link / from the Owner portal), and
/// (2) rebuilds whenever the live staff data changes.
///
/// While the session is loading it shows a spinner; if the account is not set
/// up as staff (or is deactivated) it shows the database's message instead of
/// the screen — the database refuses the data anyway, this just explains why.
class StaffDataScope extends StatefulWidget {
  final Widget Function(BuildContext context, StaffStore store) builder;

  /// When true the scope is transparent (no Scaffold) for use inside a tab.
  const StaffDataScope({super.key, required this.builder});

  @override
  State<StaffDataScope> createState() => _StaffDataScopeState();
}

class _StaffDataScopeState extends State<StaffDataScope> {
  final StaffStore _store = StaffStore.instance;

  @override
  void initState() {
    super.initState();
    _store.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        if (_store.profile != null) return widget.builder(context, _store);
        return Scaffold(
          backgroundColor: AppColors.canvas,
          appBar: AppBar(),
          body: _store.profileState.error != null
              ? StateErrorView(
                  error: _store.profileState.error,
                  onRetry: _store.start,
                )
              : const StateLoadingView(message: 'Loading your account…'),
        );
      },
    );
  }
}
