@props(['tone' => 'neutral', 'dot' => true])
<span {{ $attributes->class(['badge', $tone, 'no-dot' => ! $dot]) }}>{{ $slot }}</span>
