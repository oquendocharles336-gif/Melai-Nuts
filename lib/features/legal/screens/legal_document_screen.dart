import 'package:flutter/material.dart';

import '../../../core/config/legal_config.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/melai_app_bar.dart';
import '../../../l10n/generated/app_localizations.dart';

/// One heading + body paragraph of a legal document.
class LegalSection {
  const LegalSection(this.id, this.title, this.body);

  /// e.g. `terms.4` — matched against [LegalConfig.ownerReviewSections].
  final String id;
  final String title;
  final String body;
}

/// Scrollable, readable legal text with headings. Used by
/// [TermsAndConditionsScreen] and [PrivacyPolicyScreen]; text is translated
/// (English / Filipino) through lib/l10n.
class LegalDocumentView extends StatelessWidget {
  const LegalDocumentView({
    super.key,
    required this.title,
    required this.version,
    required this.sections,
  });

  final String title;
  final String version;
  final List<LegalSection> sections;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: MelaiAppBar(title: title, showBack: true),
      body: SafeArea(
        child: Center(
          // Comfortable reading width on tablets and the web.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Scrollbar(
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: sections.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(t.legalVersion(version), style: AppTextStyles.bodySm),
                    );
                  }
                  final s = sections[i - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(s.title, style: AppTextStyles.titleMd),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(s.body, style: AppTextStyles.bodyLg),
                        if (LegalConfig.ownerReviewSections.contains(s.id)) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            t.legalOwnerReview,
                            style: AppTextStyles.bodySm.copyWith(color: AppColors.warning),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Terms and Conditions (route `/legal/terms`, public).
class TermsAndConditionsScreen extends StatelessWidget {
  const TermsAndConditionsScreen({super.key});

  static List<LegalSection> sectionsOf(AppLocalizations t) => [
        LegalSection('terms.1', t.termsS1Title, t.termsS1Body),
        LegalSection('terms.2', t.termsS2Title, t.termsS2Body),
        LegalSection('terms.3', t.termsS3Title, t.termsS3Body),
        LegalSection('terms.4', t.termsS4Title, t.termsS4Body),
        LegalSection('terms.5', t.termsS5Title, t.termsS5Body),
        LegalSection('terms.6', t.termsS6Title, t.termsS6Body),
        LegalSection('terms.7', t.termsS7Title, t.termsS7Body),
        LegalSection('terms.8', t.termsS8Title, t.termsS8Body),
        LegalSection('terms.9', t.termsS9Title, t.termsS9Body),
      ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LegalDocumentView(
      title: t.legalTermsTitle,
      version: LegalConfig.termsVersion,
      sections: sectionsOf(t),
    );
  }
}

/// Privacy Policy (route `/legal/privacy`, public). Covers RA 10173 rights.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static List<LegalSection> sectionsOf(AppLocalizations t) => [
        LegalSection('privacy.1', t.privacyS1Title, t.privacyS1Body),
        LegalSection('privacy.2', t.privacyS2Title, t.privacyS2Body),
        LegalSection('privacy.3', t.privacyS3Title, t.privacyS3Body),
        LegalSection('privacy.4', t.privacyS4Title, t.privacyS4Body),
        LegalSection('privacy.5', t.privacyS5Title, t.privacyS5Body),
        LegalSection('privacy.6', t.privacyS6Title, t.privacyS6Body),
        LegalSection('privacy.7', t.privacyS7Title, t.privacyS7Body),
        LegalSection('privacy.8', t.privacyS8Title, t.privacyS8Body),
      ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LegalDocumentView(
      title: t.legalPrivacyTitle,
      version: LegalConfig.privacyVersion,
      sections: sectionsOf(t),
    );
  }
}
