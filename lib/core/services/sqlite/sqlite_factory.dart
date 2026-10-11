// Picks the platform's SQLite implementation without breaking web builds:
// `dart:ffi` (needed on desktop) does not exist on the web, so the real
// implementation is only compiled where `dart:io` exists.
export 'sqlite_factory_stub.dart' if (dart.library.io) 'sqlite_factory_io.dart';
