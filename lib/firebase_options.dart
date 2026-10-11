// Firebase configuration for Melai Nuts.
//
// API keys are NOT stored in source control. They are injected at build time:
//
//   flutter run --dart-define-from-file=env/firebase.json
//   flutter build apk --dart-define-from-file=env/firebase.json
//
// Copy env/firebase.example.json to env/firebase.json (git-ignored) and fill in
// the values from Firebase Console / Google Cloud Console. See SECURITY.md.
//
// Non-secret identifiers (appId, projectId, senderId, bucket) stay in code.
// Never put service-account JSON, Admin SDK keys or other private keys here.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    final options = _select();
    if (options.apiKey.isEmpty) {
      throw StateError(
        'Firebase API key is missing. Run with '
        '--dart-define-from-file=env/firebase.json '
        '(copy env/firebase.example.json first). See SECURITY.md.',
      );
    }
    return options;
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

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WEB'),
    appId: '1:865090291609:web:1ab56a62928f50fb1db508',
    messagingSenderId: '865090291609',
    projectId: 'melai-nuts-app-2026',
    authDomain: 'melai-nuts-app-2026.firebaseapp.com',
    storageBucket: 'melai-nuts-app-2026.firebasestorage.app',
  );

  // MUST match the key in android/app/google-services.json (the native SDK
  // initialises [DEFAULT] from that file; a different key here causes
  // core/duplicate-app).
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_ANDROID'),
    appId: '1:865090291609:android:231a67991e6cea8e1db508',
    messagingSenderId: '865090291609',
    projectId: 'melai-nuts-app-2026',
    storageBucket: 'melai-nuts-app-2026.firebasestorage.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WINDOWS'),
    appId: '1:865090291609:web:bdab53b6c10393f01db508',
    messagingSenderId: '865090291609',
    projectId: 'melai-nuts-app-2026',
    authDomain: 'melai-nuts-app-2026.firebaseapp.com',
    storageBucket: 'melai-nuts-app-2026.firebasestorage.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_MACOS'),
    appId: '1:865090291609:ios:860e86831b6af8691db508',
    messagingSenderId: '865090291609',
    projectId: 'melai-nuts-app-2026',
    storageBucket: 'melai-nuts-app-2026.firebasestorage.app',
    iosBundleId: 'com.example.melaiNuts',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_IOS'),
    appId: '1:865090291609:ios:860e86831b6af8691db508',
    messagingSenderId: '865090291609',
    projectId: 'melai-nuts-app-2026',
    storageBucket: 'melai-nuts-app-2026.firebasestorage.app',
    iosBundleId: 'com.example.melaiNuts',
  );
}
