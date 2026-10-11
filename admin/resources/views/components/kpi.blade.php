{{-- KPI card. Static (value/delta props) or live (Alpine expressions: x-value, x-delta, x-spark; format int|peso). --}}
@props(['label', 'icon' => 'activity', 'href' => null, 'value' => null, 'delta' => null, 'deltaNote' => 'vs previous period',
        'xValue' => null, 'xDelta' => null, 'xSpark' => null, 'format' => 'int', 'loading' => 'loading'])
<x-card :href="$href" {{ $attributes }}>
    <div class="kpi-top"><span class="icon-chip"><x-icon :name="$icon" :size="16" /></span>{{ $label }}</div>
    <div class="kpi-row">
        @if ($xValue)
            <div class="kpi-value" :class="({{ $loading }}) && 'skel'" x-count.{{ $format }}="{{ $xValue }}">—</div>
        @else
            <div class="kpi-value">{{ $value }}</div>
        @endif
        @if ($xSpark)
            <svg class="spark" viewBox="0 0 84 30" preserveAspectRatio="none" aria-hidden="true"><path :d="$spark({{ $xSpark }})" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>
        @endif
    </div>
    <div class="kpi-foot">
        @if ($xDelta)
            <span class="delta" :class="deltaClass(({{ $xDelta }}))" x-text="deltaText(({{ $xDelta }}))"></span>
            <span class="delta-note" x-show="({{ $xDelta }}) !== null && ({{ $xDelta }}) !== undefined">{{ $deltaNote }}</span>
        @elseif ($delta !== null)
            <span class="delta {{ $delta > 0 ? 'up' : ($delta < 0 ? 'down' : 'flat') }}">{{ $delta > 0 ? '↑' : ($delta < 0 ? '↓' : '') }} {{ number_format(abs($delta), 1) }}%</span>
            <span class="delta-note">{{ $deltaNote }}</span>
        @endif
        {{ $slot }}
    </div>
</x-card>
