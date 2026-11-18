# Password reset (real e-mail link, app + website)

Accounts are Firebase accounts (the app and the website share them), so the reset uses Firebase's
own password-reset e-mail — the Firebase equivalent of Supabase's `resetPasswordForEmail`. Supabase
Auth is not used for sign-in in this project.

## Flow

1. "Forgot password?" in the app (`AuthService.sendPasswordResetEmail`) or on the website
   (`LoginController@forgot` → `accounts:sendOobCode`). Unknown e-mails behave like known ones.
2. Firebase e-mails a link to **`<website>/auth/action?mode=resetPassword&oobCode=…`** (custom action URL).
3. That page (or, on a phone with the app, the app's reset screen via an Android App Link):
   * checks the code with Firebase first (`accounts:resetPassword` without a password / `verifyPasswordResetCode`);
   * asks for the new password twice and applies the same rules as sign-up (8+ characters,
     upper-case letter, number, symbol, not the e-mail/name, not a common password);
   * sets it (`confirmPasswordReset`). Firebase accepts each code **once**, so the link stops
     working, and it ends the account's other sign-ins.
   * Loading, success, expired/used-link and error states are real Firebase answers. The page sends
     `Referrer-Policy: no-referrer` and `Cache-Control: no-store`; the code is never stored or logged.

Code: `admin/app/Http/Controllers/Auth/AccountActionController.php`,
`admin/resources/views/auth/account-action.blade.php`,
`lib/features/auth/screens/reset_password_link_screen.dart`, `lib/app/routes.dart` (`/auth/action`),
`android/app/src/main/AndroidManifest.xml` (App Link). Tests: `admin/tests/Feature/AccountActionTest.php`.

## Redirect URLs to configure

| Where | Value |
|---|---|
| Firebase console → Authentication → Templates → Password reset → ✎ → **Customize action URL** | `https://<website host>/auth/action` |
| Firebase console → Authentication → Settings → Authorized domains | `<website host>` |
| `admin/.env` `APP_URL` | `https://<website host>` |
| Android build (optional, opens the link in the app) | `flutter build appbundle -PmelaiWebHost=<website host>` (or env `MELAI_WEB_HOST`) |
| `admin/.env` `ANDROID_APP_LINK_SHA256` (optional, same purpose) | SHA-256 of the app signing key (Play Console → App integrity). Serves `/.well-known/assetlinks.json` |

Without the two optional rows, every reset link opens the website page, which works for app users too.
