import 'package:flutter/material.dart';

/// Quick fade + short horizontal slide between closely related screens
/// (Welcome, Sign In and Create Account). Other screens keep the platform's
/// own page transition.
///
/// With "Reduce motion" / "Remove animations" switched on in the system
/// accessibility settings the new screen simply appears.
class FadeSlideRoute<T> extends PageRouteBuilder<T> {
  FadeSlideRoute({
    required WidgetBuilder builder,
    super.settings,
    Offset beginOffset = const Offset(0.06, 0),
  }) : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(begin: beginOffset, end: Offset.zero).animate(curved),
                child: child,
              ),
            );
          },
        );

  /// Fade only, e.g. from the splash screen into the app.
  FadeSlideRoute.fade({required WidgetBuilder builder, RouteSettings? settings})
      : this(builder: builder, settings: settings, beginOffset: Offset.zero);
}
