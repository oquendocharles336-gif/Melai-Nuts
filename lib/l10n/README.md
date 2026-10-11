# Translations (English + Filipino)

* `app_en.arb` is the template; `app_fil.arb` must have the **same keys** and the same
  `{placeholders}` (checked by `test/localization_test.dart`).
* Code is generated into `lib/l10n/generated/` by `flutter gen-l10n` (also runs on
  `flutter pub get`, because `pubspec.yaml` has `generate: true`). The folder is not committed.
* Use it in a widget: `AppLocalizations.of(context).cashOnDelivery`.
* People choose the language in **Settings → Language** (English, Filipino, or the phone's
  language). Saved on the device only (`LocaleController`).
* **The Filipino text was written by a non-native speaker and must be reviewed by a native
  speaker before release.** Owner-written text from the database (e.g. the online-payment
  notice) is shown exactly as the owner typed it, in any language.
* Covered so far: checkout payment options, catalogue / order empty states, offline POS queue,
  barcode scanner, counter returns, driver location prompt, Settings → Language. Other screens
  are still English; move a string by adding the key to both files and replacing the literal.
