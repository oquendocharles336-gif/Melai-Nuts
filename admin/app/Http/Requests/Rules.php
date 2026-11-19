<?php

namespace App\Http\Requests;

use Closure;

/**
 * The website's field rules, kept identical to the app's
 * lib/core/utils/validation_utils.dart (InputLimits) and to the database CHECK constraints
 * (supabase/migrations/20261025000000_input_check_constraints.sql). Change all three together;
 * docs/FORM_FIELDS.md lists every field.
 */
final class Rules
{
    public const NAME_MAX = 50;

    /** First name / last name each (PersonNameFields._partLimit in the app), so "First Last" fits NAME_MAX. */
    public const NAME_PART_MAX = 23;

    public const EMAIL_MAX = 254;

    public const PASSWORD_MIN = 8;

    public const PASSWORD_MAX = 64;

    public const PHONE_MAX = 16;

    public const ADDRESS_MAX = 200;

    public const NOTE_MAX = 300;

    public const REASON_MIN = 10;

    public const REASON_MAX = 500;

    /** Product review comment (InputLimits.review, product_reviews.comment). */
    public const REVIEW_MAX = 500;

    public const PRODUCT_NAME_MAX = 100;

    public const SKU_MAX = 64;

    public const QUANTITY_MAX = 99999;

    public const MONEY_MAX = 9999999.99;

    /** Letters of any alphabet (Ñ, ñ, accents), spaces, hyphens, apostrophes, periods. */
    public const NAME_REGEX = "/^[\\p{L}\\p{M}\\s'’.\\-]+$/u";

    /** A mobile number typed at sign-up: exactly 11 digits starting with 09 (ValidationUtils.validateMobile). */
    public const MOBILE_REGEX = '/^09\d{9}$/';

    /** Popular mailbox providers: only to catch typos such as gmai.com (ValidationUtils._commonEmailDomains). */
    public const COMMON_EMAIL_DOMAINS = [
        'gmail.com', 'yahoo.com', 'yahoo.com.ph', 'outlook.com', 'hotmail.com', 'icloud.com',
        'live.com', 'msn.com', 'aol.com', 'proton.me', 'protonmail.com',
    ];

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

    /**
     * First name or last name of the sign-up form, exactly like the app's PersonNameFields
     * (ValidationUtils.validateName with a 23-character part limit). $label: "First name".
     *
     * @return array<int, mixed>
     */
    public static function personName(string $label): array
    {
        return ['bail', 'required', 'string',
            function (string $attribute, mixed $value, Closure $fail) use ($label) {
                if (($error = self::personNameError($label, is_string($value) ? $value : '')) !== null) {
                    $fail($error);
                }
            }];
    }

    /** The message for one name part, or null when it is fine (same order and words as shop.js). */
    public static function personNameError(string $label, string $value): ?string
    {
        $t = trim($value);

        return match (true) {
            $t === '' => "$label is required.",
            preg_match('/\p{N}/u', $t) === 1 => "$label can't contain numbers.",
            mb_strlen($t) < 2 => "$label must be at least 2 characters.",
            mb_strlen($t) > self::NAME_PART_MAX => "$label can't be longer than ".self::NAME_PART_MAX.' characters.',
            preg_match(self::NAME_REGEX, $t) !== 1 => "$label can only use letters, spaces, hyphens, apostrophes and periods.",
            preg_match_all('/\p{L}/u', $t) < 2 => 'Please enter a real '.mb_strtolower($label).'.',
            default => null,
        };
    }

    /**
     * A NEW email address (sign-up): the app's ValidationUtils.validateEmail, typo check included
     * ("Did you mean ana@gmail.com?").
     *
     * @return array<int, mixed>
     */
    public static function newEmail(): array
    {
        return ['bail', 'required', 'string', 'max:'.self::EMAIL_MAX,
            function (string $attribute, mixed $value, Closure $fail) {
                if (($error = self::newEmailError(is_string($value) ? $value : '')) !== null) {
                    $fail($error);
                }
            }];
    }

    public static function newEmailError(string $value): ?string
    {
        $t = trim($value);
        if ($t === '') {
            return 'Email is required.';
        }
        $invalid = 'Email must look like name@example.com.';
        $at = strpos($t, '@');
        if (strlen($t) > self::EMAIL_MAX || $at === false || $at === 0 || $at !== strrpos($t, '@')) {
            return $invalid;
        }
        $local = substr($t, 0, $at);
        $labels = explode('.', substr($t, $at + 1));
        if (strlen($local) > 64 || ! preg_match("/^[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*$/", $local)) {
            return $invalid;
        }
        if (count($labels) < 2 || ! preg_match('/^[A-Za-z]{2,24}$/', end($labels))) {
            return $invalid;
        }
        foreach ($labels as $label) {
            if (! preg_match('/^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/', $label)) {
                return $invalid;
            }
        }
        $domain = strtolower(implode('.', $labels));
        if (! in_array($domain, self::COMMON_EMAIL_DOMAINS, true)) {
            foreach (self::COMMON_EMAIL_DOMAINS as $known) {
                if (self::editDistance($domain, $known) === 1) {
                    return "Did you mean $local@$known? Please check the spelling.";
                }
            }
        }

        return null;
    }

    /** Insertions, deletions, substitutions and swaps of two neighbours count 1; 2 = further apart. */
    private static function editDistance(string $a, string $b): int
    {
        $n = strlen($a);
        $m = strlen($b);
        if (abs($n - $m) > 1) {
            return 2;
        }
        $d = [];
        for ($i = 0; $i <= $n; $i++) {
            $d[$i] = [$i];
        }
        for ($j = 0; $j <= $m; $j++) {
            $d[0][$j] = $j;
        }
        for ($i = 1; $i <= $n; $i++) {
            for ($j = 1; $j <= $m; $j++) {
                $cost = $a[$i - 1] === $b[$j - 1] ? 0 : 1;
                $v = min($d[$i - 1][$j] + 1, $d[$i][$j - 1] + 1, $d[$i - 1][$j - 1] + $cost);
                if ($i > 1 && $j > 1 && $a[$i - 1] === $b[$j - 2] && $a[$i - 2] === $b[$j - 1]) {
                    $v = min($v, $d[$i - 2][$j - 2] + 1);
                }
                $d[$i][$j] = $v;
            }
        }

        return $d[$n][$m];
    }

    /**
     * The sign-up mobile number: 11 digits starting with 09 (the app's Create Account).
     *
     * @return array<int, mixed>
     */
    public static function mobile(): array
    {
        return ['bail', 'required', 'string',
            function (string $attribute, mixed $value, Closure $fail) {
                if (($error = self::mobileError(is_string($value) ? $value : '')) !== null) {
                    $fail($error);
                }
            }];
    }

    public static function mobileError(string $value): ?string
    {
        $t = trim($value);

        return match (true) {
            $t === '' => 'Mobile number is required.',
            preg_match('/^\d*$/', $t) !== 1 => 'Mobile number can only contain digits, e.g. 09171234567.',
            preg_match(self::MOBILE_REGEX, $t) !== 1 => 'Mobile number must be 11 digits starting with 09.',
            default => null,
        };
    }

    /**
     * A product review comment: optional, at most REVIEW_MAX characters, words (not only emoji).
     *
     * @return array<int, mixed>
     */
    public static function reviewComment(): array
    {
        return self::text(self::REVIEW_MAX);
    }

    /** @return array<int, mixed> */
    public static function email(bool $required = true): array
    {
        return [$required ? 'required' : 'nullable', 'string', 'email:rfc', 'max:'.self::EMAIL_MAX];
    }

    /**
     * New passwords, with the app's rules: 8 to 64 characters, an uppercase letter, a number and
     * a symbol, not the email / name, not a common password. Never trimmed (a trailing space is part of the password): Laravel's
     * TrimStrings middleware already skips password / password_confirmation.
     *
     * @return array<int, mixed>
     */
    public static function newPassword(?string $email = null, ?string $name = null): array
    {
        return ['required', 'string',
            function (string $attribute, mixed $value, Closure $fail) use ($email, $name) {
                if (! is_string($value)) {
                    return;
                }
                if (trim($value) === '') {
                    $fail('Password cannot be only spaces.');

                    return;
                }
                // The app's ValidationUtils.validatePassword, rule by rule (hasUpper / hasDigit / hasSpecial).
                $rule = match (true) {
                    mb_strlen($value) < self::PASSWORD_MIN => 'Password must be at least '.self::PASSWORD_MIN.' characters long.',
                    mb_strlen($value) > self::PASSWORD_MAX => 'Password cannot exceed '.self::PASSWORD_MAX.' characters.',
                    preg_match('/[A-Z]/', $value) !== 1 => 'Password must contain at least one uppercase letter (A-Z).',
                    preg_match('/[0-9]/', $value) !== 1 => 'Password must contain at least one number (0-9).',
                    preg_match('/[^A-Za-z0-9\s]/u', $value) !== 1 => 'Password must contain at least one special character (!@#$...).',
                    default => null,
                };
                if ($rule !== null) {
                    $fail($rule);

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
