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
/// owner and show a "draft" note. Every section up to Privacy 8 was approved
/// by the owner on 2026-11-07 (docs/owner-approval.md). Privacy 9 (product
/// photos and file access, 2026-11-17) and the 2026-11-18 update (verified
/// mobile number, first-order payment, manual payment confirmation, sign-in
/// protection, processors, retention) and the 2026-11-18.2 update (offline
/// use: Terms 10, Privacy 12, offline data in Privacy 2 and 4) wait for the
/// owner, who also fills in
/// the business name and address marked "TO BE FILLED IN BY THE OWNER".
class LegalConfig {
  LegalConfig._();

  static const String termsVersion = '2026-11-18.2';
  static const String privacyVersion = '2026-11-18.2';

  /// Section numbers whose wording still needs the owner's confirmation.
  /// They show a small "draft" note until this set is emptied.
  static const Set<String> ownerReviewSections = {
    'terms.2', 'terms.3', 'terms.6', 'terms.7', 'terms.9', 'terms.10',
    'privacy.1', 'privacy.2', 'privacy.3', 'privacy.4', 'privacy.5', 'privacy.8',
    'privacy.9', 'privacy.10', 'privacy.11', 'privacy.12',
  };
}
