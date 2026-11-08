<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="csrf-token" content="{{ csrf_token() }}">
  <title>@hasSection('title')@yield('title') · Melai Nuts @else Melai Nuts · Fresh-roasted nuts for pickup @endif</title>
  <meta name="description" content="Order Melai Nuts' fresh-roasted nuts online and pick them up at your nearest branch in Laguna.">
  <link rel="icon" type="image/svg+xml" href="{{ asset('favicon.svg') }}">
  <link rel="apple-touch-icon" href="{{ asset('apple-touch-icon.png') }}">
  <meta name="theme-color" content="#FFF9F0">
  {{-- Light by default; dark only when chosen (footer switch). Never follows the device on its own. --}}
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
<body class="shop-body">
<a class="sr-only" href="#main">Skip to content</a>

<header class="s-header">
    <div class="s-wrap s-header-row">
        <a href="{{ route('shop.home') }}" class="s-brand" aria-label="Melai Nuts shop home">
            @include('partials.logo')
            <span class="s-word">Melai Nuts</span>
        </a>

        <form class="s-search" method="GET" action="{{ route('shop.search') }}" role="search">
            <x-icon name="search" :size="17" />
            <label for="s-q" class="sr-only">Search nuts</label>
            <input id="s-q" type="search" name="q" value="{{ request()->routeIs('shop.search') ? request('q') : '' }}" placeholder="Search garlic, cashew, gift box…" maxlength="100" autocomplete="off">
        </form>

        <nav class="s-nav" aria-label="Shop">
            @if ($shopCustomer)
                <a href="{{ route('shop.orders') }}" @class(['is-on' => request()->routeIs('shop.orders*')])><x-icon name="receipt" :size="18" /><span class="hide-sm">My orders</span></a>
                <a href="{{ route('shop.points') }}" @class(['hide-sm', 'is-on' => request()->routeIs('shop.points')])><x-icon name="coins" :size="18" /><span>Points</span></a>
            @endif
            @unless ($shopStaff)
                <a href="{{ route('shop.cart') }}" class="s-cart" data-cart-target aria-label="Cart, {{ $shopCartCount }} {{ \Illuminate\Support\Str::plural('item', $shopCartCount) }}">
                    <x-icon name="bag" :size="20" /><span class="hide-sm">Cart</span>
                    <span class="s-badge" data-cart-count @if ($shopCartCount <= 0) hidden @endif>{{ $shopCartCount }}</span>
                </a>
            @endunless
            @if ($shopStaff)
                <a href="{{ route('dashboard') }}" class="s-signin">Back to dashboard</a>
            @elseif ($shopCustomer)
                <a href="{{ route('shop.account') }}" @class(['is-on' => request()->routeIs('shop.account')]) aria-label="Your account"><x-icon name="user" :size="18" /><span class="hide-sm">{{ $shopCustomer['first'] }}</span></a>
            @else
                <a href="{{ route('login') }}" class="s-signin">Sign in</a>
            @endif
        </nav>
    </div>

    <div class="s-branch" data-branch-auto>
        <div class="s-wrap">
            <x-icon name="map-pin" :size="16" />
            @if ($shopBranch)
                <span>Pickup at <b>{{ $shopBranch['name'] }}</b></span>
                @if (($shopBranch['reason'] ?? null) === 'nearest')
                    <span class="s-why">Nearest{{ isset($shopBranch['distance_km']) ? ' · '.number_format($shopBranch['distance_km'], 1).' km' : '' }}</span>
                @endif
                <button type="button" class="s-link-btn" data-locate>Update with my location</button>
            @else
                <span>Allow location and we'll pick your nearest branch for pickup.</span>
                <button type="button" class="s-link-btn" data-locate>Use my location</button>
            @endif
        </div>
    </div>
</header>

@if ($shopStaff)
    <div class="s-staffbar" role="status">
        <div class="s-wrap"><x-icon name="shield" :size="16" /><span>You're viewing the shop as <b>{{ $shopStaff }}</b>: browse only.</span>
            <a href="{{ route('dashboard') }}">Back to dashboard</a></div>
    </div>
@endif

<main id="main" class="s-main">
    <div class="s-wrap @yield('main-class')">
        @if (session('shop_status'))
            <div class="s-flash ok" role="status"><x-icon name="check" :size="18" />{{ session('shop_status') }}</div>
        @endif
        @if (session('shop_error'))
            <div class="s-flash bad" role="alert"><x-icon name="alert" :size="18" />{{ session('shop_error') }}</div>
        @endif
        @if (session('shop_note'))
            <div class="s-flash note" role="status"><x-icon name="alert" :size="18" />{{ session('shop_note') }}</div>
        @endif

        @yield('content')
    </div>
</main>

<footer class="s-footer">
    <div class="s-wrap">
        <div class="s-foot-grid">
            <div class="s-foot-brand">
                <a href="{{ route('shop.home') }}" class="s-brand" aria-label="Melai Nuts shop home">@include('partials.logo')<span class="s-word">Melai Nuts</span></a>
                <p>Fresh-roasted nuts from Laguna, in small batches. Order online and pick up at your branch. One account for the website and the Melai Nuts app.</p>
            </div>
            <div>
                <h3>Shop</h3>
                <ul>
                    <li><a href="{{ route('shop.search') }}">All nuts</a></li>
                    <li><a href="{{ route('shop.cart') }}">Cart</a></li>
                    <li><a href="{{ route('shop.orders') }}">My orders</a></li>
                    <li><a href="{{ route('shop.points') }}">Golden Kernel points</a></li>
                </ul>
            </div>
            <div>
                <h3>Branches</h3>
                <ul>
                    @forelse ($shopBranches as $b)
                        <li>{{ $b['name'] }}<small>{{ $b['hours'] ?: 'Hours not set' }}</small></li>
                    @empty
                        <li><small>Branch hours will show here.</small></li>
                    @endforelse
                </ul>
            </div>
            <div>
                <h3>Help</h3>
                <ul>
                    <li><a href="{{ route('legal.terms') }}">Terms and Conditions</a></li>
                    <li><a href="{{ route('legal.privacy') }}">Privacy Policy</a></li>
                    <li><a href="{{ route('shop.forgot') }}">Reset your password</a></li>
                    <li><a href="{{ route('login') }}">Staff and owners: sign in</a></li>
                </ul>
            </div>
        </div>
        <div class="s-foot-base">
            <span>© {{ date('Y') }} Melai Nuts Retailing · Fresh-roasted in Laguna</span>
            <div class="s-theme" role="group" aria-label="Colour theme">
                <button type="button" data-theme-set="light" aria-pressed="true"><x-icon name="sun" :size="14" />Light</button>
                <button type="button" data-theme-set="dark" aria-pressed="false"><x-icon name="moon" :size="14" />Dark</button>
            </div>
        </div>
    </div>
</footer>
</body>
</html>
