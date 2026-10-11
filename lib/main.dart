import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/services/locale_controller.dart';
import 'app/app.dart';
import 'core/services/app_check_service.dart';
import 'core/services/audit_service.dart';
import 'core/services/branch_controller.dart';
import 'core/services/connectivity_service.dart';
import 'core/services/crash_reporter.dart';
import 'core/widgets/friendly_error_widget.dart';
import 'core/services/customer_data_store.dart';
import 'core/services/data_sync_service.dart';
import 'core/services/staff_session_store.dart';
import 'core/services/staff_store.dart';
import 'core/services/supabase_service.dart';
import 'core/services/push_service.dart';
import 'core/services/sync_service.dart';
import 'data/repositories/favorites_repository.dart';
import 'data/repositories/products_repository.dart';
import 'features/customer/cart_controller.dart';
import 'features/staff/pos_sale_queue.dart';
import 'firebase_options.dart';
import 'l10n/generated/app_localizations.dart';

/// Everything runs inside [runZonedGuarded] so an async error that escapes
/// every `try` is still reported (and never ends the app silently).
/// `FlutterError.onError` and `PlatformDispatcher.instance.onError` are set
/// by [CrashReporter.init]; the binding is created inside the same zone.
void main() {
  runZonedGuarded<Future<void>>(
    _start,
    (error, stack) => CrashReporter.recordNonFatal(error, stack, context: 'uncaught-zone'),
  );
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } on FirebaseException catch (e) {
      if (e.code != 'duplicate-app') rethrow;
    }
    await CrashReporter.init();
    // Before any Firebase Auth / Firestore request (see docs/APP_CHECK.md).
    await AppCheckService.activate();
    await DataSyncService.instance.initializeLocalDatabase();
    await SupabaseService.instance.initialize();
  } catch (e, st) {
    // Show a plain message instead of a black screen. The technical detail
    // goes to the crash report (and the debug console in debug builds only);
    // it is shown on screen only in debug builds, for the developer.
    CrashReporter.recordNonFatal(e, st, context: 'startup');
    runApp(_StartupErrorApp(detail: kDebugMode ? '$e' : null));
    return;
  }
  // A widget that throws while building shows a calm message in release
  // builds instead of the red/grey error box (the error is still reported).
  installFriendlyErrorWidget();
  StaffSessionStore.instance.registerResetHook(StaffStore.instance.clear);
  // In-memory sync counters belong to one staff member; the queue itself stays
  // on disk, owned by (and only ever sent for) its own Firebase UID.
  StaffSessionStore.instance.registerResetHook(SyncService.instance.resetState);
  StaffSessionStore.instance.bindToAuth();
  // Crash reports carry the Firebase UID only (no name, e-mail or phone).
  FirebaseAuth.instance.authStateChanges().listen((user) {
    CrashReporter.setUser(user?.uid);
    if (user != null) {
      unawaited(PushService.instance.onSignedIn());
      unawaited(FavoritesRepository.instance.load());
    } else {
      FavoritesRepository.instance.clear();
    }
  });
  AuditService.instance.registerWithSync();
  PosSaleQueue.instance.register(); // offline POS sales (docs/OFFLINE_POS.md)
  SyncService.instance.attach(
    session: StaffSessionStore.instance,
    connectivity: ConnectivityService.instance,
  );
  unawaited(ProductsRepository.instance.loadCatalog());
  ConnectivityService.instance.onReconnect(() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      // Guest browsing: still worth refreshing the public catalog.
      await ProductsRepository.instance.loadCatalog(
        branchId: BranchController.instance.selectedBranch?.id,
      );
      return;
    }
    if (StaffSessionStore.instance.ownerUid == uid) {
      await Future.wait([
        ProductsRepository.instance.loadCatalog(
          branchId: BranchController.instance.selectedBranch?.id,
        ),
        StaffSessionStore.instance.refresh(),
      ]);
      if (StaffStore.instance.profile != null) {
        await StaffStore.instance.refreshAll();
      }
      return;
    }
    await Future.wait([
      ProductsRepository.instance.loadCatalog(
        branchId: BranchController.instance.selectedBranch?.id,
      ),
      CustomerDataStore.instance.refresh(),
      CartController.instance.refresh(),
    ]);
  });
  unawaited(ConnectivityService.instance.start());

  await LocaleController.instance.load();
  runApp(const MelaiNutsApp());
}

/// Shown only when startup fails (e.g. missing env/firebase.json or
/// env/supabase.json), so a config mistake is visible instead of a black screen.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({this.detail});

  /// Technical detail, debug builds only (null in release).
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          final t = AppLocalizations.of(context);
          final extra = detail;
          return Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      t.startupFailedTitle,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(t.startupFailedMessage),
                    if (extra != null) ...[
                      const SizedBox(height: 16),
                      SelectableText(extra, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
