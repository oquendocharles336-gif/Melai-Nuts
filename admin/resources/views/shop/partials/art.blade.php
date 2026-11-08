{{--
  Illustrated stand-in for a product or category photo (never a big letter). Flat, warm, and drawn
  only in the app's palette (app_colors.dart): sunEnd #FFD98F, primaryContainer #FFE6C2,
  productCardGradientStart #BE7B47, secondaryBrown #7B563F, darkBrown #2A1810, primary #BF4409,
  honey #FFC94D, gold #FFF9EC, success #33713E.
  $kind: peanut | chili | cashew | mixed | gift   ($label for screen readers, optional)
--}}
@php
    $kind = $kind ?? 'peanut';
    $peanut = 'M32 10.5C37.9 10.5 42.5 15 42.5 20.8c0 3.8-1.9 5.9-2.6 7.9-.6 1.7 1.1 3.3 2.5 5.3 1.2 1.8 1.6 3.8 1.6 6 0 7-5.4 13-12 13s-12-6-12-13c0-2.2.4-4.2 1.6-6 1.4-2 3.1-3.6 2.5-5.3-.7-2-2.6-4.1-2.6-7.9C21.5 15 26.1 10.5 32 10.5Z';
    $cashew = 'M45.5 13.5c7.5 6.5 9.2 19.7 2.6 29.8-6.9 10.6-21.2 13.6-31.4 7-4.1-2.7-3.5-8.2 1-9.2 6.8-1.6 13.4-4.6 17.3-11 3.6-6 3-11.4.9-15.4-1.6-3 5.7-4.4 9.6-1.2Z';
@endphp
<svg viewBox="0 0 200 200" class="s-art" role="img" aria-label="{{ $label ?? 'Illustration' }}" focusable="false">
    <g transform="translate(100 104) scale(1.22) translate(-100 -112)">
    @switch($kind)
        @case('cashew')
            <ellipse cx="100" cy="160" rx="62" ry="10" fill="#2A1810" opacity=".07"/>
            <g stroke="#BE7B47" stroke-width="2.4" stroke-linejoin="round">
                <path d="{{ $cashew }}" fill="#FFE6C2" transform="translate(30 38) scale(1.55) rotate(-12 32 32)"/>
                <path d="{{ $cashew }}" fill="#FFD98F" transform="translate(72 64) scale(1.5) rotate(28 32 32)"/>
                <path d="{{ $cashew }}" fill="#FFE6C2" transform="translate(40 92) scale(1.25) rotate(150 32 32)"/>
            </g>
            <g fill="#BE7B47" opacity=".35"><circle cx="78" cy="78" r="2.4"/><circle cx="132" cy="112" r="2.4"/><circle cx="84" cy="140" r="2"/></g>
            @break
        @case('mixed')
            <ellipse cx="100" cy="160" rx="70" ry="10" fill="#2A1810" opacity=".07"/>
            <path d="M30 98h140c0 38-31 66-70 66S30 136 30 98Z" fill="#BE7B47"/>
            <path d="M30 98h140c0 4-1 8-2 12H32c-1-4-2-8-2-12Z" fill="#7B563F"/>
            <g stroke="#BE7B47" stroke-width="2" stroke-linejoin="round">
                <path d="{{ $peanut }}" fill="#FFD98F" transform="translate(42 50) scale(.9) rotate(-35 32 32)"/>
                <path d="{{ $cashew }}" fill="#FFE6C2" transform="translate(88 44) scale(.95) rotate(20 32 32)"/>
                <path d="{{ $peanut }}" fill="#FFD98F" transform="translate(110 56) scale(.85) rotate(40 32 32)"/>
            </g>
            <g fill="#7B563F"><ellipse cx="78" cy="96" rx="7" ry="5" transform="rotate(-20 78 96)"/><ellipse cx="128" cy="94" rx="7" ry="5" transform="rotate(25 128 94)"/><ellipse cx="102" cy="88" rx="6" ry="4.5"/></g>
            <g fill="#BE7B47"><ellipse cx="62" cy="92" rx="9" ry="5" transform="rotate(30 62 92)"/><ellipse cx="146" cy="90" rx="9" ry="5" transform="rotate(-30 146 90)"/></g>
            @break
        @case('gift')
            <ellipse cx="100" cy="160" rx="64" ry="10" fill="#2A1810" opacity=".07"/>
            <rect x="40" y="76" width="120" height="88" rx="12" fill="#BF4409"/>
            <rect x="32" y="62" width="136" height="28" rx="9" fill="#9A3412"/>
            <rect x="90" y="62" width="20" height="102" fill="#FFC94D"/>
            <path d="M100 62c-8-20-34-26-38-12-3 11 18 14 38 12Zm0 0c8-20 34-26 38-12 3 11-18 14-38 12Z" fill="#FFC94D" stroke="#F5A623" stroke-width="2"/>
            <path d="{{ $peanut }}" fill="#FFD98F" stroke="#BE7B47" stroke-width="2" transform="translate(126 96) scale(.62) rotate(25 32 32)"/>
            <circle cx="62" cy="118" r="3" fill="#FFF9EC" opacity=".5"/><circle cx="70" cy="140" r="2" fill="#FFF9EC" opacity=".5"/>
            @break
        @case('chili')
            <ellipse cx="100" cy="160" rx="62" ry="10" fill="#2A1810" opacity=".07"/>
            <g stroke="#BE7B47" stroke-width="2.4" stroke-linejoin="round">
                <path d="{{ $peanut }}" fill="#FFD98F" transform="translate(36 40) scale(1.5) rotate(-28 32 32)"/>
                <path d="{{ $peanut }}" fill="#FFE6C2" transform="translate(84 54) scale(1.35) rotate(22 32 32)"/>
            </g>
            <path d="M58 150c22-6 40-18 48-38 2-5 8-4 8 1-2 26-26 42-54 44-6 0-8-6-2-7Z" fill="#BF4409"/>
            <path d="M112 112c2-6 6-9 10-10" stroke="#33713E" stroke-width="4" stroke-linecap="round" fill="none"/>
            <path d="M150 120c-1 4-3 6-6 9-6 4-10 9-10 16 0 9 7 15 16 15s16-6 16-15c0-7-4-12-10-16-3-3-5-5-6-9Z" fill="#FFF9EC" stroke="#BE7B47" stroke-width="2.4" stroke-linejoin="round"/>
            <path d="M150 129v28M142 133c2 8 2 16 0 22M158 133c-2 8-2 16 0 22" stroke="#BE7B47" stroke-width="1.6" fill="none" opacity=".6"/>
            @break
        @default
            <ellipse cx="100" cy="160" rx="62" ry="10" fill="#2A1810" opacity=".07"/>
            <g stroke="#BE7B47" stroke-width="2.4" stroke-linejoin="round">
                <path d="{{ $peanut }}" fill="#FFD98F" transform="translate(28 46) scale(1.45) rotate(-34 32 32)"/>
                <path d="{{ $peanut }}" fill="#FFE6C2" transform="translate(86 40) scale(1.5) rotate(18 32 32)"/>
                <path d="{{ $peanut }}" fill="#FFD98F" transform="translate(64 90) scale(1.1) rotate(80 32 32)"/>
            </g>
            <g fill="none" stroke="#BE7B47" stroke-width="2" stroke-linecap="round" opacity=".45">
                <path d="M64 70q-6 6-5 14"/><path d="M124 64q6 6 5 14"/><path d="M96 132q4 5 10 5"/>
            </g>
    @endswitch
    </g>
</svg>
