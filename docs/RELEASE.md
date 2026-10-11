# Melai Nuts — building a release

## 1. App identity (changed in this round)

| Platform | Id | Where |
|---|---|---|
| Android | `ph.melainuts.app` (was `com.example.melai_nuts`) | `android/app/build.gradle.kts` (`namespace`, `applicationId`), `MainActivity` in `android/app/src/main/java/ph/melainuts/app/` |
| iOS / macOS | `ph.melainuts.app` (was `com.example.melaiNuts`) | `ios/Runner.xcodeproj/project.pbxproj`, `macos/Runner/Configs/AppInfo.xcconfig` |

`ph.melainuts.app` is a proposal. If the business owns a domain, use its reverse form instead
(e.g. `ph.com.melainuts.app`) — change the values above **before the first Play Store / App Store
upload**: an id can never be changed after publishing.

Because the id changed, Firebase must know the new app:

1. Firebase console > Project settings > Your apps > **Add app** > Android, package `ph.melainuts.app`,
   add the SHA-1 and SHA-256 of the **release** key (step 2) and of the debug key
   (`cd android && ./gradlew signingReport`). Download `google-services.json` to
   `android/app/google-services.json` (git-ignored).
2. Add an iOS app with bundle id `ph.melainuts.app`; download `GoogleService-Info.plist` to
   `ios/Runner/` (git-ignored).
3. Put the new app IDs in `env/firebase.json` (`FIREBASE_APP_ID_ANDROID`, `FIREBASE_APP_ID_IOS`, …;
   see `env/firebase.example.json`).
4. Restrict the Android API key to package `ph.melainuts.app` + the SHA-1s (SECURITY.md, step 2).

## 2. Android release signing

```bash
keytool -genkeypair -v -keystore ~/melai-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias melai
cp android/key.properties.example android/key.properties   # fill in the 4 values
```

`android/key.properties` and `*.jks` are git-ignored. Keep the keystore and its passwords in a
password manager and a second safe place: losing them means you can never update the app.
For Play App Signing, upload this key as the *upload key*.

A release build **fails** when `key.properties` is missing (it is never signed with the debug key).

## 3. Build

```bash
flutter pub get
flutter analyze
flutter test

flutter build appbundle --release \
  --obfuscate --split-debug-info=build/symbols \
  --dart-define-from-file=env/firebase.json \
  --dart-define-from-file=env/supabase.json
```

* R8 (`isMinifyEnabled`, `isShrinkResources`) shrinks and obfuscates the Android side;
  `android/app/proguard-rules.pro` holds the few extra rules.
* `--obfuscate --split-debug-info` obfuscates the Dart side. **Keep `build/symbols/`** for each
  release (never ship it): it is needed to read crash stack traces
  (`flutter symbolize -i <trace> -d build/symbols/app.android-arm64.symbols`).
* `ONLINE_PAYMENT_ENABLED` must stay `false` (owner decision; it is `false` in the example file).

iOS: open `ios/Runner.xcworkspace` in Xcode, set the Team under Signing & Capabilities for the
Runner target (bundle id `ph.melainuts.app`), then
`flutter build ipa --release --obfuscate --split-debug-info=build/symbols --dart-define-from-file=...`.

## 4. CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | What |
|---|---|
| No hardcoded / fixture data | `scripts/check_no_fixture_data.py` (+ its tests), `scripts/build-resync.sh --check` |
| Flutter analyze + test | `flutter pub get`, `flutter analyze --fatal-warnings`, `flutter test --coverage` |
| SQL suites | `scripts/run-sql-tests.sh` on a Postgres 16 service: fresh-install check, migration re-run check, every `supabase/tests/*_test.sql` and concurrency script |
| Admin website | `php artisan test` including the Supabase integration tests on Postgres and the page-load budgets |
| Firebase Functions + Firestore rules | `functions` `npm test`, `firestore-tests` against the emulator |
| Edge Functions | `deno check` + `deno test supabase/functions/` |

**Block merges on failure:** GitHub > Settings > Branches > Add branch protection rule for `main` >
"Require a pull request before merging" + "Require status checks to pass before merging" and select
all six jobs. (This is a repository setting; it cannot be stored in the code.)
