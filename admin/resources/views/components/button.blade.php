@props(['variant' => 'outline', 'href' => null, 'type' => 'button', 'icon' => null, 'size' => null, 'label' => null])
@php $classes = ['btn', $variant => $variant !== 'outline', 'sm' => $size === 'sm', 'icon' => $label !== null && $slot->isEmpty()]; @endphp
@if ($href)
    <a href="{{ $href }}" {{ $attributes->class($classes) }} @if ($label) aria-label="{{ $label }}" @endif>@if ($icon)<x-icon :name="$icon" :size="16" />@endif{{ $slot }}</a>
@else
    <button type="{{ $type }}" {{ $attributes->class($classes) }} @if ($label) aria-label="{{ $label }}" @endif>@if ($icon)<x-icon :name="$icon" :size="16" />@endif{{ $slot }}</button>
@endif
