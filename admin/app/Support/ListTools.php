<?php

namespace App\Support;

use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Search, pagination and CSV for the list pages (Payments, Refunds, All users, Activity logs).
 * The rows are the ones the page already read (no extra database round trip), so the route
 * budgets in tests/Perf stay the same.
 */
class ListTools
{
    /** The search text from ?q= (trimmed, at most 100 characters), or ''. */
    public static function query(Request $request): string
    {
        $q = $request->query('q');

        return is_string($q) ? mb_substr(trim($q), 0, 100) : '';
    }

    /**
     * Rows whose text (from $text) contains every word of $q, ignoring case.
     *
     * @param  callable(array): string  $text
     */
    public static function search(array $rows, string $q, callable $text): array
    {
        $words = array_filter(preg_split('/\s+/', mb_strtolower($q)));
        if ($words === []) {
            return array_values($rows);
        }

        return array_values(array_filter($rows, function ($row) use ($words, $text) {
            $hay = mb_strtolower($text($row));
            foreach ($words as $w) {
                if (! str_contains($hay, $w)) {
                    return false;
                }
            }

            return true;
        }));
    }

    /** Rows per page the person can pick (the pager's "Rows" menu, on every list). */
    public const PAGE_SIZES = [10, 25, 50, 100];

    public const DEFAULT_PAGE_SIZE = 10;

    /**
     * Rows per page: ?per_page= (one of PAGE_SIZES), else the choice saved in this browser (cookie
     * melai_per_page, written by resources/js/ui.js so server and in-page lists use the same size),
     * else DEFAULT_PAGE_SIZE.
     */
    public static function perPage(Request $request): int
    {
        foreach ([$request->query('per_page'), $request->cookie('melai_per_page')] as $v) {
            if (is_scalar($v) && in_array((int) $v, self::PAGE_SIZES, true)) {
                return (int) $v;
            }
        }

        return self::DEFAULT_PAGE_SIZE;
    }

    /** The query string a pager link keeps: everything but the page and the live-refresh flags. */
    public static function linkQuery(Request $request): array
    {
        return $request->except(['page', 'fresh', 'full']);
    }

    /**
     * Page numbers to show: first, last, and the current page with one neighbour each side;
     * null marks a gap ("…"). Same rule as pageWindow() in resources/js/ui.js.
     *
     * @return array<int, int|null>
     */
    public static function pageWindow(int $current, int $last): array
    {
        $out = [];
        $prev = 0;
        for ($n = 1; $n <= $last; $n++) {
            if ($n === 1 || $n === $last || abs($n - $current) <= 1 || ($current <= 3 && $n <= 4) || ($current >= $last - 2 && $n >= $last - 3)) {
                if ($prev && $n - $prev > 1) {
                    $out[] = $n - $prev === 2 ? $n - 1 : null;
                }
                $out[] = $n;
                $prev = $n;
            }
        }

        return $out;
    }

    public static function paginate(array $rows, Request $request, ?int $perPage = null): LengthAwarePaginator
    {
        $perPage ??= self::perPage($request);
        $page = max(1, (int) $request->query('page', 1));
        $last = max(1, (int) ceil(count($rows) / $perPage));
        $page = min($page, $last);

        return new LengthAwarePaginator(array_slice(array_values($rows), ($page - 1) * $perPage, $perPage), count($rows), $perPage, $page,
            ['path' => $request->url(), 'query' => self::linkQuery($request)]);
    }

    /**
     * CSV download (UTF-8 with BOM so Excel shows ₱ and ñ; spreadsheet formulas neutralised).
     *
     * @param  array<string, callable(mixed): mixed>  $columns  header => value of a row
     */
    public static function csv(string $file, array $columns, iterable $rows): StreamedResponse
    {
        return response()->streamDownload(function () use ($columns, $rows) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF");
            fputcsv($out, array_keys($columns));
            foreach ($rows as $row) {
                fputcsv($out, array_map(fn ($get) => self::cell($get($row)), array_values($columns)));
            }
            fclose($out);
        }, $file, ['Content-Type' => 'text/csv; charset=UTF-8']);
    }

    public static function cell(mixed $v): string
    {
        $s = match (true) {
            $v === null => '',
            is_bool($v) => $v ? 'true' : 'false',
            $v instanceof \DateTimeInterface => $v->format('Y-m-d H:i:s'),
            is_array($v) => json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            default => (string) $v,
        };

        return preg_match('/^[=+\-@\t\r]/', $s) && ! is_numeric($s) ? "'".$s : $s;
    }
}
