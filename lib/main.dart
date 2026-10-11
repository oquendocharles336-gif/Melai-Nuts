import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'app/app.dart';
import 'core/services/audit_service.dart';
import 'core/services/branch_controller.dart';
import 'core/services/connectivity_service.dart';
import 'core/services/customer_data_store.dart';
import 'core/services/data_sync_service.dart';
import 'core/services/staff_session_store.dart';
import 'core/services/staff_store.dart';
import 'core/services/supabase_service.dart';
import 'core/services/sync_service.dart';
import 'data/repositories/products_repository.dart';
import 'features/customer/cart_controller.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } on FirebaseException catch (e) {
      if (e.code != 'duplicate-app') rethrow;
    }
    await DataSyncService.instance.initializeLocalDatabase();
    await SupabaseService.instance.initialize();
  } catch (e, st) {
    // Show the problem on screen instead of leaving a black screen.
    debugPrint('Startup failed: $e\n$st');
    runApp(_StartupErrorApp(message: '$e'));
    return;
  }
  StaffSessionStore.instance.registerResetHook(StaffStore.instance.clear);
  // In-memory sync counters belong to one staff member; the queue itself stays
  // on disk, owned by (and only ever sent for) its own Firebase UID.
  StaffSessionStore.instance.registerResetHook(SyncService.instance.resetState);
  StaffSessionStore.instance.bindToAuth();
  AuditService.instance.registerWithSync();
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

  runApp(const MelaiNutsApp());
}

/// Shown only when startup fails (e.g. missing env/firebase.json or
/// env/supabase.json), so a config mistake is visible instead of a black screen.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'The app could not start',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                SelectableText(message),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
