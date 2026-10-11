@props(['name', 'label', 'type' => 'text', 'autocomplete' => 'off', 'placeholder' => '', 'password' => false])
<div class="field">
    <label for="{{ $name }}">{{ $label }}</label>
    <div class="input-wrap">
        <input id="{{ $name }}" name="{{ $name }}" autocomplete="{{ $autocomplete }}" placeholder="{{ $placeholder }}"
               @if ($password) :type="show['{{ $name }}'] ? 'text' : 'password'" @else type="{{ $type }}" value="{{ old($name) }}" @endif
               x-model="values.{{ $name }}" @blur="touch('{{ $name }}')" @input="edit('{{ $name }}')"
               :class="{ 'is-invalid': error('{{ $name }}') }" :aria-invalid="error('{{ $name }}') ? 'true' : 'false'">
        @if ($password)
            <button type="button" class="toggle" @click="show['{{ $name }}'] = !show['{{ $name }}']"
                    x-text="show['{{ $name }}'] ? 'Hide' : 'Show'"></button>
        @endif
    </div>
    <p class="field-error" x-show="error('{{ $name }}')" x-text="error('{{ $name }}')" x-cloak></p>
    {{ $slot }}
</div>
