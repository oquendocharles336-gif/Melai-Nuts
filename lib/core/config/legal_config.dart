/// Versions of the legal documents shown in the app
/// (lib/features/legal/, text in lib/l10n/app_*.arb).
///
/// Bump [termsVersion] / [privacyVersion] whenever the wording changes in a
/// way people must agree to again: every signed-in user is then asked to
/// accept the new version before continuing (see LegalService), and the
/// acceptance is recorded in `public.legal_acceptances` and on the profile
/// (`terms_version`, `terms_accepted_at`).
///
/// Sections listed in [ownerReviewSections] are drafts still waiting for the
/// owner and show a "draft" note. Every section was approved by the owner on
/// 2026-11-07 (docs/owner-approval.md), so the set is empty.
class LegalConfig {
  LegalConfig._();

  static const String termsVersion = '2026-11-07';
  static const String privacyVersion = '2026-11-07';

  /// Section numbers whose wording still needs the owner's confirmation.
  /// They show a small "draft" note until this set is emptied.
  static const Set<String> ownerReviewSections = {};
}
