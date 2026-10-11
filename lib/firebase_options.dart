// Firebase configuration for Melai Nuts.
//
// NOTHING project-specific is stored in source control: the API keys AND the
// identifiers (project ID, app IDs, sender ID, bucket, bundle ID) are injected
// at build time from env/firebase.json (git-ignored):
//
//   flutter run --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
//   flutter build apk --dart-define-from-file=env/firebase.json --dart-define-from-file=env/supabase.json
//
// Copy env/firebase.example.json to env/firebase.json and fill in the values from
// Firebase console > Project settings > General > Your apps. See SECURITY.md.
// Never put service-account JSON, Admin SDK keys or other private keys here.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    final options = _select();
    if (_isPlaceholder(options.apiKey) ||
        _isPlaceholder(options.projectId) ||
        _isPlaceholder(options.appId)) {
      throw StateError(
        'Firebase configuration is missing (API key, project ID or app ID). Run with '
        '--dart-define-from-file=env/firebase.json '
        '(copy env/firebase.example.json first). See SECURITY.md.',
      );
    }
    return options;
  }

  /// True for an empty value or one still holding the env/firebase.example.json
  /// placeholder ("YOUR_…" / "your-…"), so a copied-but-unfilled file fails
  /// with the clear message above instead of an opaque Firebase error.
  static bool _isPlaceholder(String value) {
    final v = value.trim();
    return v.isEmpty || v.startsWith('YOUR_') || v.startsWith('your-');
  }

  static FirebaseOptions _select() {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const String _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const String _senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const String _bucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const String _authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const String _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WEB'),
    appId: String.fromEnvironment('FIREBASE_APP_ID_WEB'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _bucket,
  );

  // MUST match the key in android/app/google-services.json (the native SDK
  // initialises [DEFAULT] from that file; a different key here causes
  // core/duplicate-app).
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_ANDROID'),
    appId: String.fromEnvironment('FIREBASE_APP_ID_ANDROID'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _bucket,
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WINDOWS'),
    appId: String.fromEnvironment('FIREBASE_APP_ID_WINDOWS'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _bucket,
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_MACOS'),
    appId: String.fromEnvironment('FIREBASE_APP_ID_IOS'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _bucket,
    iosBundleId: _iosBundleId,
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_IOS'),
    appId: String.fromEnvironment('FIREBASE_APP_ID_IOS'),
    messagingSenderId: _senderId,
    projectId: _projectId,
    storageBucket: _bucket,
    iosBundleId: _iosBundleId,
  );
}
