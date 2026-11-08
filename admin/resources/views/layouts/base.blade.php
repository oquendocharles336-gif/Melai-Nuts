<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="csrf-token" content="{{ csrf_token() }}">
  <meta name="melai-user" content="{{ auth()->id() ?? 'guest' }}">
  <title>@yield('title', 'Melai Nuts Admin')</title>
  {{-- Melai Nuts mark (public/favicon.svg); PNG for phone home screens. --}}
  <link rel="icon" type="image/svg+xml" href="{{ asset('favicon.svg') }}">
  <link rel="apple-touch-icon" href="{{ asset('apple-touch-icon.png') }}">
  <meta name="theme-color" content="#BF4409">
  {{-- Theme before first paint (no flash). The choice is per user, saved in this browser. --}}
  <script>
    (function () {
      try {
        var u = @json((string) (auth()->id() ?? 'guest')), d = document.documentElement;
        var t = localStorage.getItem('melai.theme.' + u);
        if (t === 'light' || t === 'dark' || t === 'system') d.dataset.theme = t;
      } catch (e) {}
    })();
  </script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400..800&display=swap" rel="stylesheet">
  @vite(['resources/css/app.css', 'resources/css/melai.css', 'resources/js/app.js'])
  @stack('head')
</head>
<body class="@yield('body-class', 'light-body')">
@yield('content')
@stack('scripts')
</body>
</html>
