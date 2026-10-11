# Melai Nuts — R8 rules for the release build (isMinifyEnabled = true).
# Flutter and the Firebase / Supabase / maps plugins ship their own consumer rules;
# only what R8 reports as missing for a Flutter app is listed here.

# Flutter's deferred-components support references Play Core classes the app does not use.
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Keep line numbers for readable crash reports (the mapping file de-obfuscates names).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
