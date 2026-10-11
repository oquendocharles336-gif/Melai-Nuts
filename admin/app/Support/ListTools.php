<?php

namespace App\Support;

use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Search, pagination and CSV for the list pages (Orders, Payments, Refunds, Activity logs).
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

    public static function paginate(array $rows, Request $request, int $perPage = 25): LengthAwarePaginator
    {
        $page = max(1, (int) $request->query('page', 1));
        $last = max(1, (int) ceil(count($rows) / $perPage));
        $page = min($page, $last);

        return new LengthAwarePaginator(array_slice(array_values($rows), ($page - 1) * $perPage, $perPage), count($rows), $perPage, $page,
            ['path' => $request->url(), 'query' => $request->except('page')]);
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
