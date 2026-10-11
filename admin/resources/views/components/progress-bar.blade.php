{{-- Progress bar. Static: value + max. Live: x-width (Alpine expression giving 0-100). Optional x-tick (0-100) marks a threshold. --}}
@props(['value' => 0, 'max' => 100, 'xWidth' => null, 'xTick' => null, 'thin' => false, 'tone' => null, 'label' => null])
<div {{ $attributes->class(['progress', 'thin' => $thin, $tone => (bool) $tone]) }} role="progressbar" @if ($label) aria-label="{{ $label }}" @endif
     @if (! $xWidth) aria-valuenow="{{ $value }}" aria-valuemin="0" aria-valuemax="{{ $max }}" @endif>
    <span @if ($xWidth) :style="'width:' + ({{ $xWidth }}) + '%'" @else style="width: {{ $max > 0 ? min(100, max(0, $value / $max * 100)) : 0 }}%" @endif></span>
    @if ($xTick)<i class="tick" :style="'left:' + ({{ $xTick }}) + '%'" title="Restock level"></i>@endif
</div>
