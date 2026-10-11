import 'package:sqflite_common/sqlite_api.dart';

/// Web: there is no SQLite implementation bundled with this app, so the
/// offline staff cache is simply unavailable (callers treat that as "no
/// cache", never as an error that blocks sign-in).
Future<DatabaseFactory?> platformDatabaseFactory() async => null;

/// Where the database file lives; unused when no factory exists.
Future<String> platformDatabasePath(DatabaseFactory factory, String name) async => name;
