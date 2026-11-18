import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A random id for this installation, used by the server-side sign-in counter as one of
/// its keys (with the e-mail and the IP). It identifies nothing about the person, and the
/// server only stores a keyed hash of it. Reinstalling makes a new one; that does not reset
/// the e-mail or IP counters, which are kept on the server.
class DeviceIdStore {
  DeviceIdStore._();
  static final DeviceIdStore instance = DeviceIdStore._();

  static const String _key = 'auth_device_id_v1';
  String? _cached;

  Future<String> get() async {
    final cached = _cached;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id)) {
      final random = Random.secure();
      id = List<String>.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_key, id);
    }
    return _cached = id;
  }
}
