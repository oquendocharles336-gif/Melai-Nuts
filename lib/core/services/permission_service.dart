import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_error.dart';

/// The device permissions the app uses. Nothing else is requested.
enum AppPermission { camera, location, notifications }

/// Why a permission is being asked for (decides the explanation shown).
enum PermissionPurpose { scanBarcode, proofPhoto, pinAddress, deliveryTracking, orderUpdates }

/// Result after the explanation + system prompt.
enum PermissionOutcome { granted, denied, permanentlyDenied, unsupported }

/// What the Settings > Permissions screen shows for each permission.
enum PermissionStatusView { allowed, denied, blocked, notAsked, onUse, unsupported }

/// One place that asks for device permissions, always in this order:
///
/// 1. A short, specific explanation ([PermissionRationaleDialog]) — "Camera
///    Permission: We need access to your camera to scan product barcodes…".
/// 2. The system prompt, only if the person taps Continue.
/// 3. The result: granted; denied (what will not work + Try again);
///    permanently denied (Open Settings). Every denial leaves a manual
///    fallback on the calling screen (type the SKU, place the pin by hand…).
///
/// Permissions are requested **at the moment of use**, never at start-up.
/// Camera permission itself is requested by the camera plugins
/// (mobile_scanner / image_picker) when the camera opens; this service shows
/// the explanation first and handles their "denied" result.
class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  static const _explainedKey = 'perm.explained.';
  static const _cameraDeniedKey = 'perm.camera.denied';

  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  /// Call before opening the scanner / taking a photo. Shows the explanation
  /// the first time (and again after a denial). Returns false when the person
  /// chose "Not now" (the caller then offers its manual fallback).
  Future<bool> beforeCamera(BuildContext context, PermissionPurpose purpose) async {
    final prefs = await _prefs();
    final deniedBefore = prefs?.getBool(_cameraDeniedKey) ?? false;
    final explained = prefs?.getBool('$_explainedKey${purpose.name}') ?? false;
    if (explained && !deniedBefore) return true;
    if (!context.mounted) return false;
    final go = await PermissionRationaleDialog.show(context, AppPermission.camera, purpose);
    if (go) await prefs?.setBool('$_explainedKey${purpose.name}', true);
    return go;
  }

  /// The camera plugin reported that access was refused. Explains what will
  /// not work and offers Open Settings / Try again. Returns true for Try again.
  Future<bool> cameraDenied(BuildContext context, PermissionPurpose purpose) async {
    await (await _prefs())?.setBool(_cameraDeniedKey, true);
    if (!context.mounted) return false;
    return PermissionDeniedDialog.show(
      context,
      AppPermission.camera,
      purpose,
      // The camera plugins re-prompt on Android until "Don't ask again";
      // iOS never re-prompts, so Settings is always offered.
      permanentlyDenied: defaultTargetPlatform == TargetPlatform.iOS,
    );
  }

  /// The camera opened successfully (clears the remembered denial).
  Future<void> cameraGranted() async => (await _prefs())?.remove(_cameraDeniedKey);

  // ---------------------------------------------------------------------------
  // Location (foreground, one purpose at a time)
  // ---------------------------------------------------------------------------

  /// Whether foreground location is already allowed (never shows a prompt).
  Future<bool> locationGranted() async {
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.always || p == LocationPermission.whileInUse;
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:locationGranted');
      return false;
    }
  }

  Future<PermissionOutcome> requestLocation(BuildContext context, PermissionPurpose purpose) async {
    if (kIsWeb) return PermissionOutcome.granted; // the browser asks by itself
    try {
      var status = await Geolocator.checkPermission();
      if (status == LocationPermission.always || status == LocationPermission.whileInUse) {
        return PermissionOutcome.granted;
      }
      if (status == LocationPermission.deniedForever) {
        if (context.mounted) {
          await PermissionDeniedDialog.show(context, AppPermission.location, purpose, permanentlyDenied: true);
        }
        return PermissionOutcome.permanentlyDenied;
      }
      if (!context.mounted) return PermissionOutcome.denied;
      if (!await PermissionRationaleDialog.show(context, AppPermission.location, purpose)) {
        return PermissionOutcome.denied;
      }
      status = await Geolocator.requestPermission();
      if (status == LocationPermission.always || status == LocationPermission.whileInUse) {
        return PermissionOutcome.granted;
      }
      final forever = status == LocationPermission.deniedForever;
      if (context.mounted) {
        final retry = await PermissionDeniedDialog.show(context, AppPermission.location, purpose,
            permanentlyDenied: forever);
        if (retry && context.mounted) return await requestLocation(context, purpose);
      }
      return forever ? PermissionOutcome.permanentlyDenied : PermissionOutcome.denied;
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:location');
      return PermissionOutcome.unsupported;
    }
  }

  // ---------------------------------------------------------------------------
  // Notifications
  // ---------------------------------------------------------------------------

  bool get _pushSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Whether notifications are already allowed (never shows a prompt).
  Future<bool> notificationsAllowed() async {
    if (!_pushSupported) return false;
    try {
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      return s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:notificationsAllowed');
      return false;
    }
  }

  /// Explains, then asks for notification permission. Call after the first
  /// order, or from Settings > Permissions — never at app start.
  Future<PermissionOutcome> requestNotifications(BuildContext context, {bool force = false}) async {
    if (!_pushSupported) return PermissionOutcome.unsupported;
    try {
      final messaging = FirebaseMessaging.instance;
      final current = await messaging.getNotificationSettings();
      final auth = current.authorizationStatus;
      if (auth == AuthorizationStatus.authorized || auth == AuthorizationStatus.provisional) {
        return PermissionOutcome.granted;
      }
      if (auth == AuthorizationStatus.denied) {
        // Asked before: the system will not show its prompt again.
        if (force && context.mounted) {
          await PermissionDeniedDialog.show(context, AppPermission.notifications,
              PermissionPurpose.orderUpdates, permanentlyDenied: true);
        }
        return PermissionOutcome.permanentlyDenied;
      }
      final prefs = await _prefs();
      final key = '$_explainedKey${PermissionPurpose.orderUpdates.name}';
      // Without [force] (automatic moment, e.g. after an order) ask only once.
      if (!force && (prefs?.getBool(key) ?? false)) return PermissionOutcome.denied;
      await prefs?.setBool(key, true);
      if (!context.mounted) return PermissionOutcome.denied;
      if (!await PermissionRationaleDialog.show(
          context, AppPermission.notifications, PermissionPurpose.orderUpdates)) {
        return PermissionOutcome.denied;
      }
      final result = await messaging.requestPermission();
      final ok = result.authorizationStatus == AuthorizationStatus.authorized ||
          result.authorizationStatus == AuthorizationStatus.provisional;
      if (!ok && context.mounted) {
        await PermissionDeniedDialog.show(context, AppPermission.notifications,
            PermissionPurpose.orderUpdates, permanentlyDenied: true);
      }
      return ok ? PermissionOutcome.granted : PermissionOutcome.denied;
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:notifications');
      return PermissionOutcome.unsupported;
    }
  }

  // ---------------------------------------------------------------------------
  // Status (Settings > Permissions)
  // ---------------------------------------------------------------------------

  Future<PermissionStatusView> status(AppPermission permission) async {
    try {
      if (permission == AppPermission.camera) {
        if (!_mobile) return PermissionStatusView.unsupported;
        final denied = (await _prefs())?.getBool(_cameraDeniedKey) ?? false;
        return denied ? PermissionStatusView.denied : PermissionStatusView.onUse;
      }
      if (permission == AppPermission.location) {
        if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) {
          return PermissionStatusView.unsupported;
        }
        final p = await Geolocator.checkPermission();
        return switch (p) {
          LocationPermission.always || LocationPermission.whileInUse => PermissionStatusView.allowed,
          LocationPermission.deniedForever => PermissionStatusView.blocked,
          LocationPermission.denied => PermissionStatusView.notAsked,
          LocationPermission.unableToDetermine => PermissionStatusView.unsupported,
        };
      }
      if (!_pushSupported) return PermissionStatusView.unsupported;
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      return switch (s.authorizationStatus) {
        AuthorizationStatus.authorized || AuthorizationStatus.provisional => PermissionStatusView.allowed,
        AuthorizationStatus.denied => PermissionStatusView.blocked,
        AuthorizationStatus.notDetermined => PermissionStatusView.notAsked,
        // Newer firebase_messaging versions add more values (e.g.
        // deniedPermanently); any other "no" is shown as blocked.
        _ => PermissionStatusView.blocked,
      };
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:status');
      return PermissionStatusView.unsupported;
    }
  }

  /// Opens this app's page in the phone's Settings.
  Future<void> openAppSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:openAppSettings');
    }
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e, st) {
      AppErrors.report(e, st, 'permission_service:prefs');
      return null;
    }
  }
}

/// Title, purpose sentence and "what still works" sentence for a permission.
class PermissionTexts {
  PermissionTexts._();

  static String title(AppLocalizations t, AppPermission p) => switch (p) {
        AppPermission.camera => t.permCameraTitle,
        AppPermission.location => t.permLocationTitle,
        AppPermission.notifications => t.permNotificationsTitle,
      };

  static String purpose(AppLocalizations t, PermissionPurpose p) => switch (p) {
        PermissionPurpose.scanBarcode => t.permCameraScan,
        PermissionPurpose.proofPhoto => t.permCameraProof,
        PermissionPurpose.pinAddress => t.permLocationPin,
        PermissionPurpose.deliveryTracking => t.permLocationDelivery,
        PermissionPurpose.orderUpdates => t.permNotificationsBody,
      };

  static String fallback(AppLocalizations t, PermissionPurpose p) => switch (p) {
        PermissionPurpose.scanBarcode => t.permCameraScanFallback,
        PermissionPurpose.proofPhoto => t.permCameraProofFallback,
        PermissionPurpose.pinAddress => t.permLocationPinFallback,
        PermissionPurpose.deliveryTracking => t.permLocationDeliveryFallback,
        PermissionPurpose.orderUpdates => t.permNotificationsFallback,
      };

  static IconData icon(AppPermission p) => switch (p) {
        AppPermission.camera => Icons.photo_camera_outlined,
        AppPermission.location => Icons.location_on_outlined,
        AppPermission.notifications => Icons.notifications_outlined,
      };
}

/// The explanation shown BEFORE the system permission prompt.
class PermissionRationaleDialog extends StatelessWidget {
  const PermissionRationaleDialog({super.key, required this.permission, required this.purpose});

  final AppPermission permission;
  final PermissionPurpose purpose;

  /// True when the person tapped Continue.
  static Future<bool> show(BuildContext context, AppPermission permission, PermissionPurpose purpose) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => PermissionRationaleDialog(permission: permission, purpose: purpose),
    );
    return go ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      icon: Icon(PermissionTexts.icon(permission), color: AppColors.primary, size: 32),
      title: Text(PermissionTexts.title(t, permission)),
      content: Text(PermissionTexts.purpose(t, purpose), style: AppTextStyles.bodyMd),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.notNow)),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.permContinue),
        ),
      ],
    );
  }
}

/// Shown after a denial: what will not work, the manual fallback, and either
/// Try again (denied) or Open Settings (permanently denied).
class PermissionDeniedDialog extends StatelessWidget {
  const PermissionDeniedDialog({
    super.key,
    required this.permission,
    required this.purpose,
    required this.permanentlyDenied,
  });

  final AppPermission permission;
  final PermissionPurpose purpose;
  final bool permanentlyDenied;

  /// True when the person tapped Try again.
  static Future<bool> show(
    BuildContext context,
    AppPermission permission,
    PermissionPurpose purpose, {
    required bool permanentlyDenied,
  }) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (_) => PermissionDeniedDialog(
        permission: permission,
        purpose: purpose,
        permanentlyDenied: permanentlyDenied,
      ),
    );
    return retry ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      icon: Icon(PermissionTexts.icon(permission), color: AppColors.warning, size: 32),
      title: Text(t.permDeniedTitle(PermissionTexts.title(t, permission))),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(PermissionTexts.fallback(t, purpose), style: AppTextStyles.bodyMd),
          if (permanentlyDenied) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(t.permBlockedBody, style: AppTextStyles.bodySm),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.close)),
        if (permanentlyDenied)
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(false);
              unawaited(PermissionService.instance.openAppSettings());
            },
            child: Text(t.permOpenSettings),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.tryAgain),
          ),
      ],
    );
  }
}

/// Wrap a screen that marks "the moment of use" for notifications (e.g. the
/// order confirmation after the first order). Shortly after it appears it
/// explains and asks for notification permission — once per device — and
/// registers for pushes when allowed. Renders [child] unchanged.
class AskNotificationsOnce extends StatefulWidget {
  const AskNotificationsOnce({super.key, required this.child, required this.onGranted});

  final Widget child;

  /// Called when permission is (or already was) granted, e.g. to register
  /// the push token.
  final Future<void> Function() onGranted;

  @override
  State<AskNotificationsOnce> createState() => _AskNotificationsOnceState();
}

class _AskNotificationsOnceState extends State<AskNotificationsOnce> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Let the success animation be seen first.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      final outcome = await PermissionService.instance.requestNotifications(context);
      if (outcome == PermissionOutcome.granted) await widget.onGranted();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
