<?php

namespace App\Services\Auth;

use Illuminate\Support\Facades\Cache;

/**
 * Time-based one-time passwords (RFC 6238: HMAC-SHA1, 6 digits, 30 s), the codes made by
 * Google Authenticator, Microsoft Authenticator, Aegis, 1Password, ... No third-party library.
 */
class Totp
{
    private const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

    public static function generateSecret(int $bytes = 20): string
    {
        return self::base32Encode(random_bytes($bytes));
    }

    /** The code for $secret at time step $step (floor(unix / 30)). */
    public static function code(string $secret, int $step): string
    {
        $hash = hash_hmac('sha1', pack('N*', 0, $step), self::base32Decode($secret), true);
        $offset = ord($hash[19]) & 0x0F;
        $value = ((ord($hash[$offset]) & 0x7F) << 24) | (ord($hash[$offset + 1]) << 16)
            | (ord($hash[$offset + 2]) << 8) | ord($hash[$offset + 3]);

        return str_pad((string) ($value % 1_000_000), 6, '0', STR_PAD_LEFT);
    }

    /**
     * True when $code matches the current step or one step either side (clock drift).
     * A code that was already accepted for $replayKey is refused (no replay within its window).
     */
    public static function verify(string $secret, string $code, ?string $replayKey = null, ?int $now = null): bool
    {
        $code = preg_replace('/\s+/', '', $code);
        if (! preg_match('/^\d{6}$/', $code)) {
            return false;
        }
        $step = intdiv($now ?? time(), 30);
        foreach ([0, -1, 1] as $d) {
            if (hash_equals(self::code($secret, $step + $d), $code)) {
                if ($replayKey !== null && ! Cache::add("totp-used:$replayKey:".($step + $d), 1, 120)) {
                    return false;
                }

                return true;
            }
        }

        return false;
    }

    /** otpauth:// link an authenticator app understands (shown as text; type the key if needed). */
    public static function uri(string $issuer, string $account, string $secret): string
    {
        return 'otpauth://totp/'.rawurlencode($issuer.':'.$account).'?'.http_build_query([
            'secret' => $secret, 'issuer' => $issuer, 'algorithm' => 'SHA1', 'digits' => 6, 'period' => 30,
        ], '', '&', PHP_QUERY_RFC3986);
    }

    public static function base32Encode(string $bin): string
    {
        $bits = '';
        foreach (str_split($bin) as $c) {
            $bits .= str_pad(decbin(ord($c)), 8, '0', STR_PAD_LEFT);
        }
        $out = '';
        foreach (str_split($bits, 5) as $chunk) {
            $out .= self::ALPHABET[bindec(str_pad($chunk, 5, '0'))];
        }

        return $out;
    }

    public static function base32Decode(string $b32): string
    {
        $b32 = strtoupper(preg_replace('/[\s=-]/', '', $b32));
        $bits = '';
        foreach (str_split($b32) as $c) {
            $i = strpos(self::ALPHABET, $c);
            if ($i === false) {
                throw new \InvalidArgumentException('Invalid base32 secret.');
            }
            $bits .= str_pad(decbin($i), 5, '0', STR_PAD_LEFT);
        }
        $out = '';
        foreach (str_split($bits, 8) as $byte) {
            if (strlen($byte) === 8) {
                $out .= chr(bindec($byte));
            }
        }

        return $out;
    }
}
