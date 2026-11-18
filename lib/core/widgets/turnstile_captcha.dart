import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config/captcha_config.dart';
import '../services/connectivity_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../../l10n/generated/app_localizations.dart';

enum _CaptchaState { loading, ready, solved, expired, error, offline, unavailable }

/// Cloudflare Turnstile inside the app.
///
/// The widget runs on the website's captcha page ([CaptchaConfig.pageUrl]), so it is served
/// from our own domain with the public site key; the page hands the token back through the
/// `MelaiCaptcha` JavaScript channel. The token is checked ONLY by the server (siteverify,
/// single use, 5 minutes). This widget never decides anything.
///
/// [onToken] gets the token when the check is solved and `null` whenever it no longer is
/// (expired, reset, reloaded), so callers always send a fresh one.
class TurnstileCaptcha extends StatefulWidget {
  /// sign_in | send_code | verify_email | reset_password | change_email (must match the server's expected action).
  final String action;
  final ValueChanged<String?> onToken;

  const TurnstileCaptcha({super.key, required this.action, required this.onToken});

  @override
  State<TurnstileCaptcha> createState() => TurnstileCaptchaState();
}

class TurnstileCaptchaState extends State<TurnstileCaptcha> {
  WebViewController? _controller;
  _CaptchaState _state = _CaptchaState.loading;

  bool get _supported => !kIsWeb && CaptchaConfig.captchaAvailable &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _start(initial: true);
  }

  /// Shows a fresh challenge (after a token was used or refused).
  void reset() {
    widget.onToken(null);
    _start();
  }

  bool _initial = false;

  /// No setState while initState runs (the first build reads the fields anyway).
  void _set(_CaptchaState s) {
    if (_initial || !mounted) {
      _state = s;
    } else {
      setState(() => _state = s);
    }
  }

  void _start({bool initial = false}) {
    _initial = initial;
    try {
      _load();
    } finally {
      _initial = false;
    }
  }

  void _load() {
    if (!_supported) {
      _set(_CaptchaState.unavailable);
      return;
    }
    if (!ConnectivityService.instance.isOnline) {
      _set(_CaptchaState.offline);
      return;
    }
    _set(_CaptchaState.loading);
    final page = CaptchaConfig.pageFor(widget.action);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('MelaiCaptcha', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        // Only our own captcha page may load in the main frame; Cloudflare's challenge runs
        // in its own frame.
        onNavigationRequest: (r) => !r.isMainFrame || _sameOrigin(r.url, page)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) _set(ConnectivityService.instance.isOnline ? _CaptchaState.error : _CaptchaState.offline);
        },
      ))
      ..loadRequest(page);
    _controller = controller;
    _set(_CaptchaState.loading);
  }

  static bool _sameOrigin(String url, Uri page) {
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http')) return false;
    return u.origin == page.origin;
  }

  void _onMessage(String message) {
    if (message == 'ready') {
      if (_state == _CaptchaState.loading) _set(_CaptchaState.ready);
    } else if (message.startsWith('token:') && message.length > 6) {
      widget.onToken(message.substring(6));
      _set(_CaptchaState.solved);
    } else if (message == 'expired' || message == 'timeout') {
      widget.onToken(null);
      _set(_CaptchaState.expired);
    } else if (message.startsWith('error')) {
      widget.onToken(null);
      _set(_CaptchaState.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget status(IconData icon, Color color, String text, {bool retry = false}) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: AppTextStyles.bodySm)),
            if (retry) TextButton(onPressed: () => _start(), child: Text(t.captchaRetry)),
          ],
        );

    final Widget? message = switch (_state) {
      _CaptchaState.loading => Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Expanded(child: Text(t.captchaLoading, style: AppTextStyles.bodySm)),
        ]),
      _CaptchaState.solved => status(Icons.verified_user_rounded, AppColors.success, t.captchaSolved),
      _CaptchaState.expired => status(Icons.timer_off_outlined, AppColors.warning, t.captchaExpired, retry: true),
      _CaptchaState.error => status(Icons.error_outline_rounded, AppColors.error, t.captchaError, retry: true),
      _CaptchaState.offline => status(Icons.wifi_off_rounded, AppColors.warning, t.captchaOffline, retry: true),
      _CaptchaState.unavailable => status(Icons.info_outline_rounded, AppColors.warning, t.captchaUnavailable),
      _CaptchaState.ready => null,
    };
    final showWeb = _controller != null &&
        (_state == _CaptchaState.loading || _state == _CaptchaState.ready || _state == _CaptchaState.solved);

    return Semantics(
      container: true,
      label: t.captchaTitle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.captchaTitle, style: AppTextStyles.labelLg),
            const SizedBox(height: 8),
            if (showWeb)
              // Turnstile's managed widget is 300 x 65; a little room for its own messages.
              SizedBox(height: 78, child: WebViewWidget(controller: _controller!)),
            if (message != null) ...[
              if (showWeb) const SizedBox(height: 6),
              message,
            ],
          ],
        ),
      ),
    );
  }
}
