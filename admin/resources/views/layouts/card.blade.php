<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="csrf-token" content="{{ csrf_token() }}">
  <title>@yield('title') · Melai Nuts</title>
  <meta name="robots" content="noindex">
  <link rel="icon" type="image/svg+xml" href="{{ asset('favicon.svg') }}">
  <meta name="theme-color" content="#FFF9F0">
  {{-- The steps right after a staff sign-in (two-step code, waiting for approval), in the sign-in panel's look. --}}
  <script>
    (function () {
      var d = document.documentElement; d.classList.add('js');
      try { if (localStorage.getItem('melai.shop.theme') === 'dark') d.dataset.theme = 'dark'; } catch (e) {}
    })();
  </script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400..700;1,9..144,400..600&family=Plus+Jakarta+Sans:wght@400..800&display=swap" rel="stylesheet">
  @vite(['resources/css/melai.css', 'resources/css/shop.css', 'resources/js/shop.js'])
</head>
<body class="shop-body s-card-page">
<main class="s-card-main">
    <div class="s-dlg-card s-card-solo">
        @yield('card')
    </div>
    <p class="s-card-legal"><a href="{{ route('legal.terms') }}">Terms and Conditions</a> · <a href="{{ route('legal.privacy') }}">Privacy Policy</a></p>
</main>
</body>
</html>
