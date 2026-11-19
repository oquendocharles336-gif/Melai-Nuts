{{-- "Get the app" link (customer shop only). Hidden when APP_DOWNLOAD_URL is empty.
     $variant: 'footer' (layouts.shop footer) or 'panel' (sign-in panel). --}}
@php($appUrl = trim((string) config('melai.shop.app_download_url')))
@if ($appUrl !== '')
    @if (($variant ?? 'footer') === 'panel')
        <p class="s-dlg-aside s-app-link">Prefer the app? <a href="{{ $appUrl }}" target="_blank" rel="noopener noreferrer">Download it for Android</a>
            <small>Android only. Your phone may ask you to allow installs from your browser.</small></p>
    @else
        <p class="s-app-link"><a href="{{ $appUrl }}" target="_blank" rel="noopener noreferrer"><x-icon name="download" :size="16" />Get the Melai Nuts app for Android</a>
            <small>Android only. Your phone may ask you to allow installs from your browser.</small></p>
    @endif
@endif
