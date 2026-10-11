<!DOCTYPE html>
<html lang="en" data-theme="light" data-accent="yellow">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="csrf-token" content="{{ csrf_token() }}">
  <meta name="melai-user" content="{{ auth()->id() ?? 'guest' }}">
  <title>@yield('title', 'Melai Nuts Admin')</title>
  {{-- Inline icon: the browser never asks the server for /favicon.ico. --}}
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'%3E%3Crect width='48' height='48' rx='12' fill='%231A1A1A'/%3E%3Cg transform='rotate(-35 24 24)' fill='%23F2C14E'%3E%3Cellipse cx='24' cy='15' rx='7' ry='8'/%3E%3Cellipse cx='24' cy='32' rx='8' ry='9'/%3E%3C/g%3E%3C/svg%3E">
  {{-- Theme + accent before first paint (no flash). Choices are per user, saved in this browser. --}}
  <script>
    (function () {
      try {
        var u = @json((string) (auth()->id() ?? 'guest')), d = document.documentElement;
        var t = localStorage.getItem('melai.theme.' + u), a = localStorage.getItem('melai.accent.' + u);
        if (t === 'light' || t === 'dark' || t === 'system') d.dataset.theme = t;
        if (a === 'yellow' || a === 'mint' || a === 'pink' || a === 'blue') d.dataset.accent = a;
      } catch (e) {}
    })();
  </script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400..700&display=swap" rel="stylesheet">
  @vite(['resources/css/app.css', 'resources/css/melai.css', 'resources/js/app.js'])
  @stack('head')
</head>
<body class="@yield('body-class', 'light-body')">
@yield('content')
@stack('scripts')
</body>
</html>
