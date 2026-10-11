{{-- Grouped bars: this period (accent) vs previous (grey). `data` = Alpine expression giving [{label, cur, prev}]. --}}
@props(['data', 'height' => 260, 'label' => 'Bar chart', 'curLabel' => 'This period', 'prevLabel' => 'Previous period'])
<div class="chart" x-data="barChart" x-effect="draw({{ $data }})" x-init="h = {{ (int) $height }}" {{ $attributes }}>
    <svg x-ref="svg" :viewBox="`0 0 ${w} ${h}`" :height="h" role="img" aria-label="{{ $label }}"
         x-on:pointermove="move($event)" x-on:pointerleave="hover = null" style="touch-action: pan-y">
        <g class="grid" x-html="gridSvg"></g>
        <g class="axis" x-html="yAxisSvg"></g>
        <g class="axis" x-html="barsSvg"></g>
    </svg>
    <div class="chart-tip" x-show="tip" x-cloak :style="tip && `left:${tip.x / w * 100}%;top:${tip.y}px`">
        <b x-text="tip?.value"></b><span x-text="tip?.label + (tip?.prev !== null && tip?.prev !== undefined ? ', was ' + tip.prev : '')"></span>
    </div>
    <div class="legend" style="margin-top:10px"><span><i style="background:var(--accent)"></i>{{ $curLabel }}</span><span><i style="background:var(--surface-3)"></i>{{ $prevLabel }}</span></div>
</div>
