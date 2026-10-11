{{-- 4-step order stepper. `state` is an Alpine expression returning '', 'current' or 'done' for step index i. --}}
@props(['steps' => ['New', 'Packing', 'Shipped', 'Delivered'], 'state'])
<ol class="stepper" style="list-style:none;padding:0" aria-label="Order progress">
    @foreach ($steps as $i => $label)
        <li class="step" :class="({{ $state }})({{ $i }})" :aria-current="({{ $state }})({{ $i }}) === 'current' ? 'step' : null">
            <span class="step-dot">
                <template x-if="({{ $state }})({{ $i }}) === 'done'"><x-icon name="check" :size="14" :stroke="2.6" /></template>
                <template x-if="({{ $state }})({{ $i }}) !== 'done'"><span style="font-size:11px;font-weight:700">{{ $i + 1 }}</span></template>
            </span>
            <span>{{ $label }}</span>
        </li>
    @endforeach
</ol>
