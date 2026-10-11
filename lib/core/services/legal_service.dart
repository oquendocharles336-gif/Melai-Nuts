import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/routes.dart';
import '../../l10n/generated/app_localizations.dart';
import '../config/legal_config.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_error.dart';
import 'auth_service.dart';
import 'supabase_service.dart';

/// Records that the signed-in person accepted the current Terms and
/// Conditions and Privacy Policy ([LegalConfig]) and asks them to accept again
/// when the version changes.
///
/// Server side: `public.accept_legal_terms(...)` appends to
/// `public.legal_acceptances` (who, which document, which version, when) and
/// stamps `terms_version` / `terms_accepted_at` on the person's profile
/// (migration 20261025040000_legal_acceptance.sql). The device keeps only the
/// last accepted version per account (a small setting), so the check also
/// works offline and an acceptance made offline is sent later.
class LegalService {
  LegalService._();
  static final LegalService instance = LegalService._();

  static String _acceptedKey(String uid) => 'legal.accepted.$uid';
  static String _pendingKey(String uid) => 'legal.pending.$uid';

  /// The version string both documents must match (they are accepted together).
  static String get currentVersion =>
      '${LegalConfig.termsVersion}|${LegalConfig.privacyVersion}';

  /// Pure rule (unit-tested): must someone who last accepted [accepted] accept again?
  static bool needsAcceptance(String? accepted) => accepted != currentVersion;

  /// Consent given on a form (registration) before the account exists; it is
  /// recorded for whichever account signs in next on this device.
  bool _consentGivenOnForm = false;
  bool? _orderUpdatesOptIn;
  bool _prompting = false;
  final Set<String> _checkedThisSession = {};

  /// Call when a form with the consent checkbox was submitted with it ticked.
  void markConsentGiven({bool? orderUpdates}) {
    _consentGivenOnForm = true;
    _orderUpdatesOptIn = orderUpdates;
  }

  /// Records acceptance of the current version for [uid] (best effort: when
  /// offline it is kept on the device and sent by the next [ensureAccepted]).
  Future<void> recordAcceptance(String uid, {bool? orderUpdates}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_acceptedKey(uid), currentVersion);
    try {
      await AppErrors.guard(() async => await SupabaseService.instance.client.rpc('accept_legal_terms', params: {
            'p_terms_version': LegalConfig.termsVersion,
            'p_privacy_version': LegalConfig.privacyVersion,
            'p_order_updates': orderUpdates,
          }));
      await prefs.remove(_pendingKey(uid));
    } catch (e, st) {
      AppErrors.report(e, st, 'legal_service:recordAcceptance');
      await prefs.setString(_pendingKey(uid), currentVersion);
    }
  }

  /// The version this account last accepted: the server's answer when it can
  /// be reached, otherwise the copy on this device.
  Future<String?> _acceptedVersion(String uid, SharedPreferences prefs) async {
    try {
      final raw = await AppErrors.guard(
        () async => await SupabaseService.instance.client.rpc('my_legal_acceptance'),
        timeout: const Duration(seconds: 10),
      );
      if (raw is Map) {
        final terms = raw['terms_version'] as String?;
        final privacy = raw['privacy_version'] as String?;
        final v = (terms == null || privacy == null) ? null : '$terms|$privacy';
        if (v != null) await prefs.setString(_acceptedKey(uid), v);
        return v ?? prefs.getString(_acceptedKey(uid));
      }
    } catch (e, st) {
      AppErrors.report(e, st, 'legal_service:acceptedVersion');
      // Offline: trust the device copy. With no copy, do not block the person.
      return prefs.getString(_acceptedKey(uid)) ?? currentVersion;
    }
    return prefs.getString(_acceptedKey(uid));
  }

  /// Called by the route guard once a signed-in screen is allowed. Sends any
  /// acceptance made offline, records a consent ticked on the registration
  /// form, and otherwise shows the "We updated our terms" dialog when the
  /// person has not accepted the current version. Runs once per account per
  /// app session.
  Future<void> ensureAccepted(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _prompting || _checkedThisSession.contains(user.uid)) return;
    _checkedThisSession.add(user.uid);
    final uid = user.uid;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_consentGivenOnForm) {
        _consentGivenOnForm = false;
        await recordAcceptance(uid, orderUpdates: _orderUpdatesOptIn);
        return;
      }
      if (prefs.getString(_pendingKey(uid)) == currentVersion) {
        await recordAcceptance(uid);
        return;
      }
      final accepted = await _acceptedVersion(uid, prefs);
      if (!needsAcceptance(accepted)) return;
      if (!context.mounted) return;
      _prompting = true;
      final agreed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ReacceptDialog(),
      );
      _prompting = false;
      if (agreed == true) {
        await recordAcceptance(uid);
      } else if (agreed == false) {
        await AuthService.instance.signOut();
        if (context.mounted) {
          await Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (r) => false);
        }
      } else {
        // The dialog was closed by navigation; ask again on the next screen.
        _checkedThisSession.remove(uid);
      }
    } catch (e, st) {
      _prompting = false;
      _checkedThisSession.remove(uid);
      AppErrors.report(e, st, 'legal_service:ensureAccepted');
    }
  }

  /// Forget the per-session check (sign-out / account switch).
  void resetSession() {
    _checkedThisSession.clear();
    _consentGivenOnForm = false;
    _orderUpdatesOptIn = null;
  }
}

class _ReacceptDialog extends StatelessWidget {
  const _ReacceptDialog();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(t.legalUpdatedTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.legalUpdatedBody, style: AppTextStyles.bodyMd),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.description_outlined),
              label: Text(t.legalTermsTitle),
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalTerms),
            ),
            TextButton.icon(
              icon: const Icon(Icons.privacy_tip_outlined),
              label: Text(t.legalPrivacyTitle),
              onPressed: () => Navigator.of(context).pushNamed(AppRoutes.legalPrivacy),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.signOut),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.iAgree),
          ),
        ],
      ),
    );
  }
}
