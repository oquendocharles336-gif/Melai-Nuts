{{-- Smooth line chart with accent area, hover guide, dot and tooltip. `data` = Alpine expression giving [{date, value}]. --}}
@props(['data', 'height' => 260, 'label' => 'Line chart'])
<div class="chart" x-data="lineChart" x-effect="draw({{ $data }})" x-init="h = {{ (int) $height }}" {{ $attributes }}>
    <svg x-ref="svg" :viewBox="`0 0 ${w} ${h}`" :height="h" role="img" aria-label="{{ $label }}"
         x-on:pointermove="move($event)" x-on:pointerleave="hover = null" style="touch-action: pan-y">
        <g class="grid" x-html="gridSvg"></g>
        <g class="axis" x-html="yAxisSvg"></g>
        <g class="axis" x-html="xAxisSvg"></g>
        <path class="area" :class="drawing && 'draw'" :d="areaPath" />
        <path class="line" :class="drawing && 'draw'" :d="linePath" pathLength="1" stroke-dasharray="1" />
        <line class="guide" x-show="tip" :x1="tip?.x ?? 0" :x2="tip?.x ?? 0" :y1="pad.t" :y2="h - pad.b" />
        <circle class="dot" x-show="tip" :cx="tip?.x ?? 0" :cy="tip?.y ?? 0" r="5" />
    </svg>
    <div class="chart-tip" x-show="tip" x-cloak :style="tip && `left:${tip.x / w * 100}%;top:${tip.y}px`"><b x-text="tip?.value"></b><span x-text="tip?.date"></span></div>
    <p class="empty" x-show="empty && series.length" x-cloak style="position:absolute;inset:auto 0 40% 0;padding:0">No confirmed sales in this period.</p>
</div>
