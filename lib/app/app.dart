import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';
import 'route_guard.dart';
import 'routes.dart';

/// Root widget of the Melai Nuts Retailing Android app.
class MelaiNutsApp extends StatelessWidget {
  const MelaiNutsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Melai Nuts Retailing',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      initialRoute: AppRoutes.splash,
      routes: AppRoutes.routes,
      onGenerateRoute: (settings) => AppRoutes.onGenerateRoute(settings),
      onUnknownRoute: (settings) => MaterialPageRoute<dynamic>(
        settings: settings,
        builder: (_) => const UnavailableRouteScreen(),
      ),
    );
  }
}
