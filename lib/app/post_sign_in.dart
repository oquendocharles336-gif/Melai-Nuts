import 'package:flutter/widgets.dart';

import '../data/models/user_role.dart';
import 'routes.dart';

/// Where a customer goes once they have signed in, when signing in
/// interrupted something (Proceed to Checkout as a guest).
///
/// Kept here rather than passed along as a route argument because sign-in
/// can take several screens: Sign In, Create Account, the email code, or the
/// phone code. Whichever one finishes calls [go].
class PostSignIn {
  PostSignIn._();

  /// An abandoned sign-in doesn't send someone to the cart much later.
  static const Duration maxAge = Duration(minutes: 30);

  static String? _route;
  static DateTime? _setAt;

  /// Remember to open [route] after the next customer sign-in.
  static void returnTo(String route) {
    _route = route;
    _setAt = DateTime.now();
  }

  static void clear() {
    _route = null;
    _setAt = null;
  }

  /// The remembered route if it is still fresh, and forgets it.
  static String? take({DateTime? now}) {
    final route = _route;
    final setAt = _setAt;
    clear();
    if (route == null || setAt == null) return null;
    if ((now ?? DateTime.now()).difference(setAt) > maxAge) return null;
    return route;
  }

  /// Replaces the whole stack with [role]'s home. For a customer who was
  /// sent to sign in from somewhere (their cart), that screen opens on top,
  /// so Back from it goes to the store, never to the sign-in screens.
  static void go(NavigatorState navigator, UserRole role) {
    final target = take();
    navigator.pushNamedAndRemoveUntil(AppRoutes.homeFor(role), (r) => false);
    if (role == UserRole.customer && target != null) navigator.pushNamed(target);
  }
}
