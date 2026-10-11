import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/auth_service.dart';
import '../core/services/staff_session_store.dart';
import '../core/theme/app_colors.dart';
import '../data/models/user_role.dart';
import '../features/staff/widgets/staff_session_blocked_view.dart';
import 'routes.dart';

/// Client-side access gate for a screen.
///
/// IMPORTANT: this is defence-in-depth and good UX — it stops people landing
/// on screens that aren't theirs (deep links, stale navigation, a session that
/// was revoked). It is NOT the security boundary: a modified app can skip it.
/// The real enforcement is Firestore Security Rules (`firestore.rules`), which
/// check the caller's Firebase identity and server-stored role on every read
/// and write.
///
/// The protected screen is only *built* after access has been confirmed, using
/// the validated profile from [AuthService] (never a locally stored role).
///
/// STAFF: a signed-in staff member's screens are additionally held back until
/// [StaffSessionStore] has confirmed their Supabase profile, branch and
/// permissions for exactly the account that is signed in. If the session is
/// cleared (logout, account switch) the screen is swapped for a neutral view
/// on the spot, so one staff member's data is never shown to the next.
class RouteGuard extends StatefulWidget {
  const RouteGuard({
    super.key,
    required this.builder,
    this.allowedRoles,
    this.allowGuest = false,
    this.requiredPermissions = const <String>{},
  });

  final WidgetBuilder builder;

  /// Roles allowed to view the screen. `null` = any signed-in role.
  final Set<UserRole>? allowedRoles;

  /// Whether an unauthenticated visitor may view it (public catalog browsing).
  final bool allowGuest;

  /// Permissions (see `StaffPermission`) a signed-in STAFF member must hold to
  /// see the screen. Owners hold every permission and are not checked. UX only:
  /// the database enforces the same rules on every request.
  final Set<String> requiredPermissions;

  @override
  State<RouteGuard> createState() => _RouteGuardState();
}

class _RouteGuardState extends State<RouteGuard> {
  StreamSubscription<User?>? _sub;
  bool _allowed = false;
  bool _redirecting = false;
  bool _hasBuilt = false;

  /// Set when this screen was opened by a staff member: the Firebase UID the
  /// screen is bound to. It never changes for the life of the guard, so if the
  /// session is later cleared or replaced the screen locks instead of showing
  /// the next account an unbound (or the previous account's) staff UI.
  String? _staffUid;

  bool get _customerOnly =>
      widget.allowedRoles != null &&
      widget.allowedRoles!.length == 1 &&
      widget.allowedRoles!.contains(UserRole.customer);

  @override
  void initState() {
    super.initState();
    final auth = AuthService.instance;

    // Fast path: profile already validated this session -> no spinner frame.
    final profile = auth.currentProfile;
    if (auth.currentFirebaseUser == null) {
      if (widget.allowGuest) _allowed = true;
    } else if (profile != null && _roleAllowed(profile.role)) {
      _allowed = true;
      if (profile.role == UserRole.staff) _staffUid = profile.uid;
    }

    _sub = auth.authStateChanges.listen(_onAuthChanged);
    if (!_allowed) _evaluate();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool _roleAllowed(UserRole role) {
    final roles = widget.allowedRoles;
    return roles == null || roles.contains(role);
  }

  void _onAuthChanged(User? user) {
    if (user != null || _redirecting || !mounted) return;
    if (widget.allowGuest) return; // guests may stay
    // The logout flow drives its own navigation; only react to unexpected
    // sign-outs (revoked/expired session, account removed).
    if (AuthService.instance.userInitiatedSignOut) return;
    _deny(
      message: 'Your session has ended. Please sign in again.',
      route: AppRoutes.login,
      clearStack: true,
    );
  }

  Future<void> _evaluate() async {
    final auth = AuthService.instance;
    if (auth.currentFirebaseUser == null) {
      _deny(
        message: _customerOnly ? 'Please sign in to continue.' : null,
        route: AppRoutes.login,
      );
      return;
    }

    try {
      final profile = auth.currentProfile ?? await auth.loadCurrentProfile();
      if (!mounted) return;
      if (profile == null) {
        _deny(route: AppRoutes.login);
        return;
      }
      if (!_roleAllowed(profile.role)) {
        _deny(
          message: "You don't have access to that area.",
          route: AppRoutes.homeFor(profile.role),
        );
        return;
      }
      setState(() {
        _allowed = true;
        if (profile.role == UserRole.staff) _staffUid = profile.uid;
      });
    } on AuthException catch (e) {
      _deny(message: e.message, route: AppRoutes.login, clearStack: true);
    } catch (_) {
      _deny(
        message: 'We could not verify your account. Please sign in again.',
        route: AppRoutes.login,
        clearStack: true,
      );
    }
  }

  void _deny({String? message, required String route, bool clearStack = false}) {
    if (_redirecting || !mounted) return;
    _redirecting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (message != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      if (clearStack) {
        navigator.pushNamedAndRemoveUntil(route, (r) => false);
      } else {
        navigator.pushReplacementNamed(route);
      }
    });
    // Hide protected content immediately (not applicable during initState).
    if (_hasBuilt) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _hasBuilt = true;
    if (_allowed && !_redirecting) {
      final staffUid = _staffUid;
      if (staffUid != null) {
        return ListenableBuilder(
          listenable: StaffSessionStore.instance,
          builder: (context, _) {
            final session = StaffSessionStore.instance;
            if (!session.isReadyFor(staffUid)) return const StaffSessionBlockedView();
            if (!session.canAll(widget.requiredPermissions)) {
              return const StaffPermissionDeniedView();
            }
            return widget.builder(context);
          },
        );
      }
      return widget.builder(context);
    }
    return const Scaffold(
      backgroundColor: AppColors.canvas,
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

/// Shown for unknown routes or routes opened with invalid arguments, instead
/// of crashing with a cast error.
class UnavailableRouteScreen extends StatelessWidget {
  const UnavailableRouteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: const Text('Not available')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This page is not available.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .pushNamedAndRemoveUntil(AppRoutes.splash, (r) => false),
                child: const Text('Go back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
