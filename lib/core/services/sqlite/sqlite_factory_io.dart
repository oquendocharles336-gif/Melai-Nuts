import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Android / iOS use the sqflite plugin; Windows / Linux / macOS use the FFI
/// implementation (needs the platform's sqlite3 library — bundled on macOS,
/// `libsqlite3` on Linux, `sqlite3.dll` next to the executable on Windows).
Future<DatabaseFactory?> platformDatabaseFactory() async {
  if (Platform.isAndroid || Platform.isIOS) return mobile.databaseFactory;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    ffi.sqfliteFfiInit();
    return ffi.databaseFactoryFfi;
  }
  return null;
}

Future<String> platformDatabasePath(DatabaseFactory factory, String name) async {
  final dir = await factory.getDatabasesPath();
  return p.join(dir, name);
}
