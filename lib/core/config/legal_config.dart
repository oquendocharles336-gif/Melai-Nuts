/// Versions of the legal documents shown in the app
/// (lib/features/legal/, text in lib/l10n/app_*.arb).
///
/// Bump [termsVersion] / [privacyVersion] whenever the wording changes in a
/// way people must agree to again: every signed-in user is then asked to
/// accept the new version before continuing (see LegalService), and the
/// acceptance is recorded in `public.legal_acceptances` and on the profile
/// (`terms_version`, `terms_accepted_at`).
///
/// TODO(owner): the sections marked [ownerReviewSections] are plain-language
/// drafts. Melai Nuts must confirm them (refund time limit, retention periods,
/// registered business name, data protection officer contact) before release,
/// then bump the versions.
class LegalConfig {
  LegalConfig._();

  static const String termsVersion = '2026-10-11';
  static const String privacyVersion = '2026-10-11';

  /// Section numbers whose wording still needs the owner's confirmation.
  /// They show a small "draft" note until this set is emptied.
  static const Set<String> ownerReviewSections = {
    'terms.4', // refund time limit
    'terms.5', // loyalty rule changes notice period
    'privacy.1', // registered business name / DPO contact
    'privacy.5', // retention periods
    'privacy.7', // deletion request channel
  };
}
