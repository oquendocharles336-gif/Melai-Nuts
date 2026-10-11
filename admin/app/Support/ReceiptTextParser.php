<?php

namespace App\Support;

/**
 * Turns the text OCR read from a supplier invoice into a DRAFT purchase receipt.
 *
 * It only suggests: invoice number, date, total, supplier and item lines (description,
 * quantity, unit cost) with the best-matching product. A person reviews every field before
 * anything is posted to stock (staff_approve_purchase_receipt), so a wrong guess costs a
 * correction, never wrong stock.
 *
 * Handles the usual Philippine invoice layouts, e.g.
 *     Garlic Peanuts 250g     20    85.00    1,700.00      (description qty unit amount)
 *     Cashew 100g  10 @ 150.00   1500.00                    (qty @ unit amount)
 *     12 pcs Adobo Mani 85.00 1,020.00                      (leading quantity)
 *     Kasoy Brittle x5 ₱60.00                               (x qty, unit)
 */
class ReceiptTextParser
{
    private const SKIP_WORDS = [
        'total', 'subtotal', 'sub-total', 'vat', 'vatable', 'zero-rated', 'exempt', 'amount due', 'balance',
        'change', 'cash', 'tendered', 'discount', 'tin', 'invoice', 'receipt', 'date', 'thank', 'cashier',
        'customer', 'address', 'tel', 'phone', 'sold to', 'terms', 'page', 'signature', 'received by',
        'prepared by', 'qty', 'description', 'unit price', 'permit', 'accreditation', 'bir', 'serial',
    ];

    /**
     * @param  array<int, array{id: string, label: string}>  $variants  products to match lines against
     * @param  array<int, array{id: string, name: string}>  $suppliers
     * @return array{invoice_no: ?string, invoice_date: ?string, total: ?float, supplier_id: ?string,
     *               lines: array<int, array{raw_text: string, description: string, quantity: ?int,
     *               unit_cost: ?float, amount: ?float, variant_id: ?string, match: float, checked: bool}>}
     */
    public function parse(string $text, array $variants = [], array $suppliers = []): array
    {
        $text = str_replace(["\r\n", "\r", "\t"], ["\n", "\n", '  '], $text);
        $lines = array_values(array_filter(array_map(fn ($l) => trim(preg_replace('/[ ]{3,}/', '  ', $l)), explode("\n", $text)), fn ($l) => $l !== ''));

        $items = [];
        foreach ($lines as $line) {
            $item = $this->parseLine($line);
            if ($item !== null) {
                [$item['variant_id'], $item['match']] = $this->bestMatch($item['description'], $variants, 'label');
                $items[] = $item;
            }
        }

        return [
            'invoice_no' => $this->invoiceNo($text),
            'invoice_date' => $this->invoiceDate($text),
            'total' => $this->total($lines),
            'supplier_id' => $this->supplier(array_slice($lines, 0, 6), $suppliers),
            'lines' => array_slice($items, 0, 200),
        ];
    }

    /** One item line, or null for headers, totals and noise. */
    public function parseLine(string $line): ?array
    {
        $lower = mb_strtolower($line);
        foreach (self::SKIP_WORDS as $w) {
            if (preg_match('/(^|[^a-z])'.preg_quote($w, '/').'([^a-z]|$)/', $lower)) {
                return null;
            }
        }

        // Date lines ("Oct 7, 2026", "10/08/2026", "2026-10-08") are never items.
        if ($this->invoiceDate($line) !== null && ! preg_match('/\d+\.\d{2}\s*$/', $line)) {
            return null;
        }

        $clean = $this->fixOcrDigits($line);
        $clean = preg_replace('/(₱|\bPHP\b|\bPhp\b|\bP(?=\s?\d))/u', ' ', $clean);

        // "10 @ 150.00" / "x5" / "5x" / "5 pcs"
        $qtyHint = null;
        $unitHint = null;
        if (preg_match('/(?<![\w.])(\d{1,5})\s*(?:pcs?|packs?|pks?|bags?|boxes|box|btl|kgs?|units?|x)?\s*@\s*(\d[\d,]*(?:\.\d{1,2})?)/i', $clean, $m)) {
            [$qtyHint, $unitHint] = [(int) $m[1], $this->num($m[2])];
            $clean = str_replace($m[0], ' ', $clean);
        } elseif (preg_match('/(?<![\w.])(?:x\s*(\d{1,5})|(\d{1,5})\s*x)(?![\w.])/i', $clean, $m)) {
            $qtyHint = (int) ($m[1] !== '' ? $m[1] : $m[2]);
            $clean = str_replace($m[0], ' ', $clean);
        } elseif (preg_match('/^\s*(\d{1,5})\s*(?:pcs?|packs?|pks?|bags?|boxes|box|btl|units?)\b\.?/i', $clean, $m)) {
            $qtyHint = (int) $m[1];
            $clean = substr($clean, strlen($m[0]));
        }

        // Standalone numbers (not "250g", not part of a word).
        preg_match_all('/(?<![\w.\/-])(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)(?![\w%\/-])/', $clean, $m, PREG_OFFSET_CAPTURE);
        $numbers = $m[1];

        // The trailing number group: numbers at the end of the line with no words between them.
        $tail = [];
        $end = strlen($clean);
        for ($i = count($numbers) - 1; $i >= 0; $i--) {
            $numEnd = $numbers[$i][1] + strlen($numbers[$i][0]);
            if (preg_match('/\p{L}/u', substr($clean, $numEnd, $end - $numEnd))) {
                break;
            }
            array_unshift($tail, $numbers[$i]);
            $end = $numbers[$i][1];
        }
        $tail = array_slice($tail, -3);
        $descEnd = $tail ? $tail[0][1] : strlen($clean);
        $description = trim(preg_replace('/\s{2,}/', ' ', preg_replace('/^[\s\-–•*#.]+|[\s\-–:]+$/u', '', substr($clean, 0, $descEnd))));
        $vals = array_map(fn ($n) => $this->num($n[0]), $tail);

        if (mb_strlen($description) < 3 || ! preg_match('/\p{L}{2,}/u', $description)) {
            return null;
        }
        if ($vals === [] && $qtyHint === null) {
            return null;
        }

        [$qty, $unit, $amount] = $this->assign($vals, $qtyHint, $unitHint);
        // A lone number (an address with a ZIP code, a reference) is not an item line.
        if ($qty === null && $unit === null) {
            return null;
        }

        return [
            'raw_text' => mb_substr($line, 0, 500),
            'description' => mb_substr($description, 0, 200),
            'quantity' => $qty,
            'unit_cost' => $unit,
            'amount' => $amount,
            'checked' => $qty !== null && $unit !== null && $amount !== null && abs($qty * $unit - $amount) <= max(1, 0.01 * $amount),
            'variant_id' => null,
            'match' => 0.0,
        ];
    }

    /** @return array{0: ?int, 1: ?float, 2: ?float} quantity, unit cost, line amount */
    private function assign(array $vals, ?int $qtyHint, ?float $unitHint): array
    {
        $isInt = fn ($v) => $v !== null && floor($v) == $v && $v >= 1 && $v <= 100000;

        if ($qtyHint !== null && $unitHint !== null) {
            return [$qtyHint, $unitHint, $vals ? end($vals) : round($qtyHint * $unitHint, 2)];
        }
        if ($qtyHint !== null) {
            if (count($vals) >= 2) {
                return [$qtyHint, $vals[count($vals) - 2], end($vals)];
            }
            if (count($vals) === 1) {
                // one price after an explicit quantity: unit price if it doesn't look like the total
                return [$qtyHint, $vals[0], round($qtyHint * $vals[0], 2)];
            }

            return [$qtyHint, null, null];
        }
        $n = count($vals);
        if ($n >= 3) {
            // ... qty unit amount (take the last three; earlier numbers are codes/sizes)
            [$a, $b, $c] = array_slice($vals, -3);
            if ($isInt($a) && abs($a * $b - $c) <= max(1, 0.01 * $c)) {
                return [(int) $a, $b, $c];
            }
            if ($isInt($b) && abs($b * $a - $c) <= max(1, 0.01 * $c)) {   // unit qty amount
                return [(int) $b, $a, $c];
            }

            return [$isInt($a) ? (int) $a : null, $b, $c];
        }
        if ($n === 2) {
            [$a, $b] = $vals;
            if ($isInt($a) && $b >= $a && $a <= 1000) {
                // qty + amount (the usual two-column layout); unit cost derived
                return [(int) $a, round($b / $a, 2), $b];
            }

            return [null, $a, $b];
        }
        if ($n === 1) {
            return [null, null, $vals[0]];
        }

        return [null, null, null];
    }

    /** "1,7OO.OO" -> "1,700.00": O/o/l/I inside a number are OCR mistakes. */
    private function fixOcrDigits(string $s): string
    {
        return preg_replace_callback('/(?<![A-Za-z])[\dOoIl][\dOoIl,.]*\d[\dOoIl,.]*(?![A-Za-z])/', fn ($m) => strtr($m[0], ['O' => '0', 'o' => '0', 'I' => '1', 'l' => '1']), $s);
    }

    private function num(string $s): float
    {
        return round((float) str_replace(',', '', $s), 2);
    }

    public function invoiceNo(string $text): ?string
    {
        $patterns = [
            '/\b(?:sales\s+)?invoice\s*(?:no\.?|number|#)?\s*[:#.]?\s*([A-Z]{0,4}[-\s]?\d[\w-]{1,20})/i',
            '/\b(?:SI|OR|DR|INV)\s*(?:no\.?|#)?\s*[:#.]?\s*(\d[\w-]{1,20})/i',
            '/\b(?:SI|OR|DR|INV)-(\d[\w-]{1,20})/i',
            '/\breceipt\s*(?:no\.?|number|#)\s*[:#.]?\s*([\w-]{3,20})/i',
            '/\bno\.\s*([0-9]{3,12})\b/i',
        ];
        foreach ($patterns as $p) {
            if (preg_match($p, $text, $m)) {
                return strtoupper(trim(str_replace(' ', '', $m[1])));
            }
        }

        return null;
    }

    public function invoiceDate(string $text): ?string
    {
        $months = 'jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec';
        $candidates = [];
        if (preg_match_all('/\b(20\d{2})[-\/.](\d{1,2})[-\/.](\d{1,2})\b/', $text, $ms, PREG_SET_ORDER)) {
            foreach ($ms as $m) {
                $candidates[] = [(int) $m[1], (int) $m[2], (int) $m[3]];
            }
        }
        if (preg_match_all('/\b(\d{1,2})[-\/.](\d{1,2})[-\/.](20\d{2}|\d{2})\b/', $text, $ms, PREG_SET_ORDER)) {
            foreach ($ms as $m) {
                $y = strlen($m[3]) === 2 ? 2000 + (int) $m[3] : (int) $m[3];
                $candidates[] = [$y, (int) $m[1], (int) $m[2]];   // PH invoices: month/day/year
            }
        }
        if (preg_match_all('/\b('.$months.')[a-z]*\.?\s+(\d{1,2}),?\s+(20\d{2})\b/i', $text, $ms, PREG_SET_ORDER)) {
            foreach ($ms as $m) {
                $candidates[] = [(int) $m[3], $this->month($m[1]), (int) $m[2]];
            }
        }
        if (preg_match_all('/\b(\d{1,2})[\s-]+('.$months.')[a-z]*\.?[\s-]+(20\d{2})\b/i', $text, $ms, PREG_SET_ORDER)) {
            foreach ($ms as $m) {
                $candidates[] = [(int) $m[3], $this->month($m[2]), (int) $m[1]];
            }
        }
        foreach ($candidates as [$y, $mo, $d]) {
            if (checkdate($mo, $d, $y)) {
                return sprintf('%04d-%02d-%02d', $y, $mo, $d);
            }
            if (checkdate($d, $mo, $y)) {            // day/month/year written the other way
                return sprintf('%04d-%02d-%02d', $y, $d, $mo);
            }
        }

        return null;
    }

    private function month(string $m): int
    {
        return array_search(substr(strtolower($m), 0, 3), ['', 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'], true) ?: 1;
    }

    private function total(array $lines): ?float
    {
        $found = null;
        foreach ($lines as $line) {
            $fixed = $this->fixOcrDigits($line);
            if (preg_match('/\b(?:grand\s+)?total(?:\s+amount)?(?:\s+due)?\b[^\d]*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*$/i', $fixed, $m)
                && ! preg_match('/\bsub[\s-]?total\b/i', $fixed)) {
                $found = $this->num($m[1]); // the last "total" line wins (grand total)
            }
        }

        return $found;
    }

    private function supplier(array $headerLines, array $suppliers): ?string
    {
        $best = [null, 0.0];
        foreach ($headerLines as $line) {
            [$id, $score] = $this->bestMatch($line, $suppliers, 'name');
            if ($score > $best[1]) {
                $best = [$id, $score];
            }
        }

        return $best[1] >= 0.6 ? $best[0] : null;
    }

    /** @return array{0: ?string, 1: float} best id and a 0..1 score (null below 0.5) */
    public function bestMatch(string $text, array $options, string $field): array
    {
        $a = $this->tokens($text);
        if ($a === []) {
            return [null, 0.0];
        }
        $best = [null, 0.0];
        foreach ($options as $o) {
            $b = $this->tokens($o[$field] ?? '');
            if ($b === []) {
                continue;
            }
            // token overlap (with fuzzy token equality for OCR typos) + whole-string similarity
            $hits = 0;
            foreach ($b as $tb) {
                foreach ($a as $ta) {
                    if ($ta === $tb || (strlen($tb) >= 4 && levenshtein($ta, $tb) <= 1)) {
                        $hits++;
                        break;
                    }
                }
            }
            $overlap = $hits / count($b);
            similar_text(implode(' ', $a), implode(' ', $b), $pct);
            $score = round(0.7 * $overlap + 0.3 * ($pct / 100), 3);
            if ($score > $best[1]) {
                $best = [$o['id'], $score];
            }
        }

        return $best[1] >= 0.5 ? $best : [null, $best[1]];
    }

    /** lower-case words without sizes, units and filler ("Garlic Peanuts 250g" -> [garlic, peanuts]). */
    private function tokens(string $s): array
    {
        $s = mb_strtolower($s);
        $s = preg_replace('/\b\d+(?:\.\d+)?\s*(?:g|gm|grams?|kg|kgs|ml|l|oz|pcs?|packs?)\b/u', ' ', $s);
        $words = preg_split('/[^\p{L}\p{N}]+/u', $s, -1, PREG_SPLIT_NO_EMPTY);
        $stop = ['the', 'and', 'of', 'inc', 'corp', 'co', 'ltd', 'regular', 'pack', 'pc', 'pcs', 'x'];

        return array_values(array_filter($words, fn ($w) => mb_strlen($w) >= 2 && ! in_array($w, $stop, true) && ! is_numeric($w)));
    }
}
