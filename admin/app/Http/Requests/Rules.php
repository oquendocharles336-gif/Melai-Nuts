<?php

namespace App\Http\Requests;

use Closure;
use Illuminate\Validation\Rules\Password;

/**
 * The website's field rules, kept identical to the app's
 * lib/core/utils/validation_utils.dart (InputLimits) and to the database CHECK constraints
 * (supabase/migrations/20261025000000_input_check_constraints.sql). Change all three together;
 * docs/FORM_FIELDS.md lists every field.
 */
final class Rules
{
    public const NAME_MAX = 50;

    public const EMAIL_MAX = 254;

    public const PASSWORD_MIN = 8;

    public const PASSWORD_MAX = 64;

    public const PHONE_MAX = 16;

    public const ADDRESS_MAX = 200;

    public const NOTE_MAX = 300;

    public const REASON_MIN = 10;

    public const REASON_MAX = 500;

    public const PRODUCT_NAME_MAX = 100;

    public const SKU_MAX = 64;

    public const QUANTITY_MAX = 99999;

    public const MONEY_MAX = 9999999.99;

    /** Letters of any alphabet (Ñ, ñ, accents), spaces, hyphens, apostrophes, periods. */
    public const NAME_REGEX = "/^[\\p{L}\\p{M}\\s'’.\\-]+$/u";

    /** Philippine mobile: 09XXXXXXXXX, 9XXXXXXXXX, 639XXXXXXXXX or +639XXXXXXXXX (spaces/dashes allowed). */
    public const PH_MOBILE_REGEX = '/^(?:\+63|63|0)?9\d{9}$/';

    /** Same weak-password words as ValidationUtils._weakPasswordWords in the app. */
    private const WEAK_WORDS = [
        'password', 'passw', 'pass', 'pword', 'qwerty', 'qwertyuiop', 'asdf', 'asdfgh',
        'zxcvbn', 'welcome', 'admin', 'administrator', 'letmein', 'iloveyou', 'abc',
        'abcd', 'abcdef', 'abcdefg', 'monkey', 'dragon', 'football', 'baseball',
        'sunshine', 'princess', 'master', 'login', 'changeme', 'secret', 'melainuts',
        'melai', 'nuts', 'test', 'user', 'qazwsx', 'trustno', 'iloveu', 'mahalkita',
    ];

    /** @return array<int, mixed> */
    public static function name(bool $required = true): array
    {
        return [$required ? 'required' : 'nullable', 'string', 'min:2', 'max:'.self::NAME_MAX, 'regex:'.self::NAME_REGEX,
            function (string $attribute, mixed $value, Closure $fail) {
                if (is_string($value) && preg_match_all('/\p{L}/u', $value) < 2) {
                    $fail('Please enter a valid name.');
                }
            }];
    }

    /** @return array<int, mixed> */
    public static function email(bool $required = true): array
    {
        return [$required ? 'required' : 'nullable', 'string', 'email:rfc', 'max:'.self::EMAIL_MAX];
    }

    /**
     * New passwords. Never trimmed (a trailing space is part of the password): Laravel's
     * TrimStrings middleware already skips password / password_confirmation.
     *
     * @return array<int, mixed>
     */
    public static function newPassword(?string $email = null, ?string $name = null): array
    {
        return ['required', 'string', 'max:'.self::PASSWORD_MAX,
            Password::min(self::PASSWORD_MIN)->mixedCase()->numbers()->symbols(),
            function (string $attribute, mixed $value, Closure $fail) use ($email, $name) {
                if (! is_string($value)) {
                    return;
                }
                if (trim($value) === '') {
                    $fail('Password cannot be only spaces.');

                    return;
                }
                $lower = mb_strtolower($value);
                $local = mb_strtolower(explode('@', trim((string) $email))[0] ?? '');
                if (mb_strlen($local) >= 3 && str_contains($lower, $local)) {
                    $fail('Password must not contain your email address.');

                    return;
                }
                foreach (preg_split('/[\s\-.]+/u', mb_strtolower((string) $name)) ?: [] as $part) {
                    if (mb_strlen($part) >= 3 && str_contains($lower, $part)) {
                        $fail('Password must not contain your name.');

                        return;
                    }
                }
                if (self::isCommonPassword($value)) {
                    $fail('This password is too common. Choose something harder to guess.');
                }
            }];
    }

    public static function isCommonPassword(string $password): bool
    {
        $lower = mb_strtolower($password);
        $letters = fn (string $v) => preg_replace('/[^a-z]/', '', $v);
        if ($letters($lower) === '') {
            return true;
        }
        $leet = strtr($lower, ['@' => 'a', '0' => 'o', '3' => 'e', '$' => 's']);
        foreach ([$letters($lower), $letters($leet), $letters(strtr($leet, ['1' => 'i'])), $letters(strtr($leet, ['1' => 'l']))] as $c) {
            if (in_array($c, self::WEAK_WORDS, true)) {
                return true;
            }
        }

        return false;
    }

    /** @return array<int, mixed> */
    public static function phone(bool $required = false): array
    {
        return [$required ? 'required' : 'nullable', 'string', 'max:20',
            function (string $attribute, mixed $value, Closure $fail) {
                if (is_string($value) && trim($value) !== '' && self::phToE164($value) === null) {
                    $fail('Please enter a valid Philippine mobile number, e.g. 0917 123 4567.');
                }
            }];
    }

    /** "0917 123 4567" -> "+639171234567"; null when it is not a PH mobile number. */
    public static function phToE164(?string $input): ?string
    {
        $clean = preg_replace('/[\s\-().]/', '', (string) $input);

        return preg_match(self::PH_MOBILE_REGEX, $clean) ? '+63'.substr($clean, -10) : null;
    }

    /** The one stored format (E.164) for a PH mobile; anything else trimmed as typed. */
    public static function normalizePhone(?string $input): ?string
    {
        if ($input === null || trim($input) === '') {
            return null;
        }

        return self::phToE164($input) ?? trim($input);
    }

    /**
     * Free text: trimmed, at most $max characters, must contain a letter or digit (no emoji-only).
     *
     * @return array<int, mixed>
     */
    public static function text(int $max = self::NOTE_MAX, int $min = 0, bool $required = false): array
    {
        return [$required || $min > 0 ? 'required' : 'nullable', 'string', 'max:'.$max, ...($min > 0 ? ['min:'.$min] : []),
            function (string $attribute, mixed $value, Closure $fail) {
                if (is_string($value) && trim($value) !== '' && ! preg_match('/[\p{L}\p{N}]/u', $value)) {
                    $fail('This field must contain words, not only emoji or symbols.');
                }
            }];
    }

    /** @return array<int, mixed> */
    public static function reason(int $min = self::REASON_MIN, int $max = self::REASON_MAX): array
    {
        return self::text($max, $min, true);
    }

    /** @return array<int, mixed> */
    public static function money(bool $required = true, float $min = 0, float $max = self::MONEY_MAX): array
    {
        return [$required ? 'required' : 'nullable', 'numeric', 'min:'.$min, 'max:'.$max, 'decimal:0,2'];
    }

    /** @return array<int, mixed> */
    public static function quantity(int $min = 1, int $max = self::QUANTITY_MAX, bool $required = true): array
    {
        return [$required ? 'required' : 'nullable', 'integer', 'min:'.$min, 'max:'.$max];
    }

    /** @return array<int, mixed> */
    public static function sku(bool $required = false): array
    {
        return [$required ? 'required' : 'nullable', 'string', 'max:'.self::SKU_MAX, 'regex:/^[A-Za-z0-9._-]+$/'];
    }

    /** Shared messages so the website says the same thing as the app. */
    public static function messages(): array
    {
        return [
            'name.regex' => 'Name should only contain letters, spaces, hyphens, apostrophes or periods.',
            'name.min' => 'Name must be at least 2 characters long.',
            'name.max' => 'Name cannot exceed '.self::NAME_MAX.' characters.',
            'email.email' => 'Please enter a valid email address (e.g. user@example.com).',
            'password.max' => 'Password cannot exceed '.self::PASSWORD_MAX.' characters.',
            'decimal' => 'The :attribute can have at most 2 decimal places.',
        ];
    }
}
