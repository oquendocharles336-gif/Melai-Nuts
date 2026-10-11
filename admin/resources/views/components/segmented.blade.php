{{-- Segmented control. options: [value => label]; model: Alpine expression holding the value;
     change: optional Alpine function name called with the value instead of assigning it. --}}
@props(['options', 'model', 'change' => null, 'light' => false, 'label' => 'Options', 'icons' => []])
<div {{ $attributes->class(['seg', 'light' => $light]) }} role="radiogroup" aria-label="{{ $label }}">
    @foreach ($options as $value => $text)
        @php $js = \Illuminate\Support\Js::from($value); @endphp
        <button type="button" role="radio" :aria-checked="({{ $model }}) === {{ $js }} ? 'true' : 'false'" :class="({{ $model }}) === {{ $js }} && 'is-on'"
                x-on:click="{{ $change ? $change.'('.$js.')' : $model.' = '.$js }}">@isset($icons[$value])<x-icon :name="$icons[$value]" :size="14" />@endisset{{ $text }}</button>
    @endforeach
</div>
