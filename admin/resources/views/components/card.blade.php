@props(['title' => null, 'subtitle' => null, 'href' => null, 'flush' => false])
@php $tag = $href ? 'a' : 'section'; @endphp
<{{ $tag }} @if ($href) href="{{ $href }}" @endif {{ $attributes->class(['ui-card', 'flush' => $flush]) }}>
    @if ($title || isset($actions))
        <header class="ui-card-head" @if ($flush) style="padding:18px 20px 0" @endif>
            <div>
                @if ($title)<h2 class="ui-card-title">{{ $title }}</h2>@endif
                @if ($subtitle)<p class="ui-card-sub">{{ $subtitle }}</p>@endif
            </div>
            @isset($actions)<div class="page-actions">{{ $actions }}</div>@endisset
        </header>
    @endif
    {{ $slot }}
    @if ($href)<x-icon name="chevron-right" class="card-chevron" :size="16" />@endif
</{{ $tag }}>
