import 'package:melai_nuts/core/services/sqlite_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A fresh in-memory database with the REAL schema (`SqliteService.migrations`).
/// Requires the platform's sqlite3 library (see README of sqflite_common_ffi).
Future<Database> openTestDatabase() {
  sqfliteFfiInit();
  return SqliteService.openWith(databaseFactoryFfi, inMemoryDatabasePath);
}
