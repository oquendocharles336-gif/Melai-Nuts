<?php

namespace App\Support;

use Illuminate\Support\Facades\Log;
use RuntimeException;

/**
 * The profanity check for product reviews and order special instructions (English and
 * Filipino / Tagalog). The word list is ONE shared file, moderation/blocked_words.json at the
 * project root (config melai.moderation.words_file); see moderation/README.md.
 *
 * The same algorithm runs in the browser (resources/js/shop.js, fed by clientData()), in the app
 * (lib/core/moderation/blocked_words.dart) and in the database (migration 20261119030000), so a
 * message blocked here is blocked everywhere. scripts/test_blocked_words.py checks they agree.
 *
 * What it catches: any case, repeated letters (fuuuck), letters split by spaces or symbols
 * (f u c k, f.u.c.k), leetspeak (@ 4 = a, 1 ! | = i, 0 = o, 3 = e, $ 5 = s, 7 = t) and accents
 * (puñeta). Ordinary words are matched as whole words only, so "class", "assess" or "Batangas"
 * pass; only the few "roots" are also caught inside longer words.
 */
final class BlockedWords
{
    private const ACCENTS = ['á' => 'a', 'à' => 'a', 'â' => 'a', 'ä' => 'a', 'ã' => 'a', 'é' => 'e', 'è' => 'e', 'ê' => 'e', 'ë' => 'e',
        'í' => 'i', 'ì' => 'i', 'î' => 'i', 'ï' => 'i', 'ó' => 'o', 'ò' => 'o', 'ô' => 'o', 'ö' => 'o', 'õ' => 'o',
        'ú' => 'u', 'ù' => 'u', 'û' => 'u', 'ü' => 'u', 'ñ' => 'n'];

    private const LEET = ['@' => 'a', '4' => 'a', '1' => 'i', '!' => 'i', '|' => 'i', '0' => 'o', '3' => 'e', '$' => 's', '5' => 's', '7' => 't'];

    public const DEFAULT_MESSAGE = 'Please keep your message respectful.';

    /** @var array{message: string, words: list<string>, roots: list<string>, phrases: list<string>, allow: list<string>}|null */
    private static ?array $list = null;

    /** @var array{allow: array<string, true>, wordMin: array<string, int>, roots: list<string>, longWords: list<string>, phrases: list<string>}|null */
    private static ?array $compiled = null;

    /** True when the text contains a blocked word (in any of the disguises above). */
    public static function contains(?string $text): bool
    {
        if ($text === null || trim($text) === '') {
            return false;
        }
        $c = self::compiled();
        [$plain, $leet, $squeezed] = self::sequences($text);
        foreach ([...$plain, ...$leet, ...$squeezed] as $w) {
            if (self::isWord($w, $c)) {
                return true;
            }
        }
        foreach ([$plain, $leet] as $seq) {
            foreach (self::runs($seq) as $joined) {
                if (isset($c['allow'][$joined])) {
                    continue;
                }
                if (self::isWord($joined, $c)) {
                    return true;
                }
                $cj = self::collapse($joined);
                foreach ($c['longWords'] as $x) {
                    if (str_contains($cj, $x)) {
                        return true;
                    }
                }
            }
            $line = ' '.implode(' ', array_map(self::collapse(...), $seq)).' ';
            foreach ($c['phrases'] as $p) {
                if (str_contains($line, ' '.$p.' ')) {
                    return true;
                }
            }
        }

        return false;
    }

    /** The friendly message shown under the field. */
    public static function message(): string
    {
        return self::raw()['message'];
    }

    /** What the browser check needs (shop.js): the lists and the message. */
    public static function clientData(): array
    {
        $l = self::raw();

        return ['message' => $l['message'], 'words' => $l['words'], 'roots' => $l['roots'], 'phrases' => $l['phrases'], 'allow' => $l['allow']];
    }

    /** Tests: forget the loaded list (e.g. after pointing the config at another file). */
    public static function flush(): void
    {
        self::$list = null;
        self::$compiled = null;
    }

    private static function raw(): array
    {
        if (self::$list !== null) {
            return self::$list;
        }
        $file = (string) config('melai.moderation.words_file');
        $json = is_file($file) ? json_decode((string) file_get_contents($file), true) : null;
        if (! is_array($json) || ! isset($json['words']) || ! is_array($json['words'])) {
            // Never silently stop filtering: an unreadable list is a setup error.
            Log::error("Blocked words list missing or invalid: $file (config melai.moderation.words_file).");
            throw new RuntimeException('The blocked words list could not be loaded.');
        }
        $clean = fn ($v) => array_values(array_filter(array_map(fn ($w) => is_string($w) ? mb_strtolower(trim($w)) : '', is_array($v) ? $v : []), fn ($w) => $w !== ''));

        return self::$list = [
            'message' => is_string($json['message'] ?? null) && $json['message'] !== '' ? $json['message'] : self::DEFAULT_MESSAGE,
            'words' => $clean($json['words']),
            'roots' => $clean($json['roots'] ?? []),
            'phrases' => $clean($json['phrases'] ?? []),
            'allow' => $clean($json['allow'] ?? []),
        ];
    }

    private static function compiled(): array
    {
        if (self::$compiled !== null) {
            return self::$compiled;
        }
        $l = self::raw();
        $wordMin = [];
        foreach ($l['words'] as $w) {
            $k = self::collapse($w);
            $wordMin[$k] = min($wordMin[$k] ?? PHP_INT_MAX, strlen($w));
        }

        return self::$compiled = [
            'allow' => array_fill_keys($l['allow'], true),
            'wordMin' => $wordMin,
            'roots' => array_map(self::collapse(...), $l['roots']),
            'longWords' => array_values(array_map(self::collapse(...), array_filter($l['words'], fn ($w) => strlen($w) >= 4))),
            'phrases' => array_map(fn ($p) => implode(' ', array_map(self::collapse(...), preg_split('/\s+/', $p))), $l['phrases']),
        ];
    }

    private static function isWord(string $w, array $c): bool
    {
        if ($w === '' || isset($c['allow'][$w])) {
            return false;
        }
        $forms = [$w];
        if (strlen($w) >= 4 && str_ends_with($w, 's')) {
            $forms[] = substr($w, 0, -1);
        }
        if (strlen($w) >= 5 && str_ends_with($w, 'es')) {
            $forms[] = substr($w, 0, -2);
        }
        foreach ($forms as $f) {
            $min = $c['wordMin'][self::collapse($f)] ?? null;
            if ($min !== null && strlen($f) >= $min) {
                return true;
            }
        }
        $cw = self::collapse($w);
        foreach ($c['roots'] as $r) {
            if (str_contains($cw, $r)) {
                return true;
            }
        }

        return false;
    }

    /** @return array{0: list<string>, 1: list<string>, 2: list<string>} plain words, leet words, squeezed chunks */
    private static function sequences(string $text): array
    {
        $t = strtr(mb_strtolower($text), self::ACCENTS);
        $plain = $leet = $squeezed = [];
        foreach (preg_split('/\s+/u', $t, -1, PREG_SPLIT_NO_EMPTY) as $chunk) {
            $variants = [$chunk];
            if (preg_match('/[a-z@$!|]/', $chunk)) {
                $variants[] = strtr($chunk, self::LEET);
            }
            foreach ($variants as $i => $v) {
                $parts = preg_split('/[^a-z]+/', $v, -1, PREG_SPLIT_NO_EMPTY);
                if ($i === 0) {
                    array_push($plain, ...$parts);
                    if (count($variants) === 1) {
                        array_push($leet, ...$parts);
                    }
                } else {
                    array_push($leet, ...$parts);
                }
                $squeezed[] = preg_replace('/[^a-z]+/', '', $v);
            }
        }

        return [$plain, $leet, $squeezed];
    }

    /** Three or more single letters in a row (f u c k), joined. @return list<string> */
    private static function runs(array $seq): array
    {
        $out = [];
        $run = [];
        foreach ([...$seq, ''] as $tok) {
            if (strlen($tok) === 1) {
                $run[] = $tok;

                continue;
            }
            if (count($run) >= 3) {
                $out[] = implode('', $run);
            }
            $run = [];
        }

        return $out;
    }

    private static function collapse(string $s): string
    {
        return (string) preg_replace('/(.)\1+/', '$1', $s);
    }
}
