{{--
    The Melai Nuts app's security check (lib/core/widgets/turnstile_captcha.dart).
    Opened in the app's WebView: renders Turnstile from THIS domain with the public site key and
    hands the token to the app through the MelaiCaptcha JavaScript channel. The token is checked
    only by the Supabase Edge Functions. A normal browser just sees the widget.
--}}
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="robots" content="noindex">
<title>Melai Nuts security check</title>
<style>
  html, body { margin: 0; padding: 0; background: transparent; font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; color: #1F120B; }
  .wrap { display: flex; justify-content: center; padding: 4px 0; }
  .msg { font-size: 13px; text-align: center; color: #6E5E50; }
</style>
@if ($siteKey !== '')
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=melaiReady&render=explicit" async defer></script>
@endif
</head>
<body>
<div class="wrap"><div id="widget"></div></div>
@if ($siteKey === '')
<p class="msg">The security check is not set up yet.</p>
@endif
<script>
  function post(message) {
    try { if (window.MelaiCaptcha) window.MelaiCaptcha.postMessage(message); } catch (e) {}
  }
  @if ($siteKey === '')
  post('error:not_configured');
  @endif
  function melaiReady() {
    post('ready');
    turnstile.render('#widget', {
      sitekey: @json($siteKey),
      action: @json($action),
      theme: 'light',
      'refresh-expired': 'manual',
      callback: function (token) { post('token:' + token); },
      'expired-callback': function () { post('expired'); },
      'timeout-callback': function () { post('timeout'); },
      'error-callback': function (code) { post('error:' + code); return true; }
    });
  }
</script>
</body>
</html>
