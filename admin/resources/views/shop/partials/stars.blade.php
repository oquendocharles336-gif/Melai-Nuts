{{-- Five stars filled up to $rating (to the nearest half). Decorative: give the text next to it. --}}
@php($halves = (int) round(((float) $rating) * 2))
@php($gid = 'sh'.\Illuminate\Support\Str::random(8))
<span class="s-stars" aria-hidden="true">
    @for ($i = 1; $i <= 5; $i++)
        @if ($halves >= $i * 2)
            <svg viewBox="0 0 24 24"><path fill="currentColor" d="M12 17.3l-6.2 3.7 1.6-7L2 9.2l7.1-.6L12 2l2.9 6.6 7.1.6-5.4 4.8 1.6 7z"/></svg>
        @elseif ($halves === $i * 2 - 1)
            <svg viewBox="0 0 24 24"><defs><linearGradient id="{{ $gid }}"><stop offset="50%" stop-color="currentColor"/><stop offset="50%" stop-color="currentColor" stop-opacity=".25"/></linearGradient></defs><path fill="url(#{{ $gid }})" d="M12 17.3l-6.2 3.7 1.6-7L2 9.2l7.1-.6L12 2l2.9 6.6 7.1.6-5.4 4.8 1.6 7z"/></svg>
        @else
            <svg viewBox="0 0 24 24"><path fill="currentColor" fill-opacity=".25" d="M12 17.3l-6.2 3.7 1.6-7L2 9.2l7.1-.6L12 2l2.9 6.6 7.1.6-5.4 4.8 1.6 7z"/></svg>
        @endif
    @endfor
</span>
