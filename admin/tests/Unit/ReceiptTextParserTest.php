<?php

namespace Tests\Unit;

use App\Support\ReceiptTextParser;
use PHPUnit\Framework\TestCase;

class ReceiptTextParserTest extends TestCase
{
    private const VARIANTS = [
        ['id' => 'v-garlic', 'label' => 'Garlic Peanuts · 250g'],
        ['id' => 'v-adobo', 'label' => 'Adobo Mani'],
        ['id' => 'v-cashew', 'label' => 'Roasted Cashew · 100g'],
        ['id' => 'v-brittle', 'label' => 'Kasoy Brittle'],
    ];

    private const SUPPLIERS = [
        ['id' => 's-lnt', 'name' => 'Laguna Nut Traders'],
        ['id' => 's-bic', 'name' => 'Bicol Cashew Farms'],
    ];

    private function sample(): string
    {
        return <<<'TXT'
LAGUNA NUT TRADERS
Brgy. Real, Calamba City, Laguna   TIN 123-456-789-000
SALES INVOICE No. 0042
Date: 10/08/2026
QTY  DESCRIPTION            UNIT PRICE   AMOUNT
Garlic Peanuts 250g     20    85.00    1,7OO.OO
Roasted Cashew 100g  10 @ 150.00   1500.00
12 pcs Adobo Mani 60.00 720.00
Kasoy Brittle x5 P75.00
Sub-Total 4,295.00
VAT 12%  460.18
TOTAL AMOUNT DUE  4,295.00
Thank you!
TXT;
    }

    public function test_header_fields(): void
    {
        $r = (new ReceiptTextParser)->parse($this->sample(), self::VARIANTS, self::SUPPLIERS);
        $this->assertSame('0042', $r['invoice_no']);
        $this->assertSame('2026-10-08', $r['invoice_date']);
        $this->assertSame(4295.0, $r['total']);
        $this->assertSame('s-lnt', $r['supplier_id']);
    }

    public function test_item_lines_in_four_layouts(): void
    {
        $lines = (new ReceiptTextParser)->parse($this->sample(), self::VARIANTS, self::SUPPLIERS)['lines'];
        $this->assertCount(4, $lines, json_encode($lines));

        [$g, $c, $a, $k] = $lines;
        $this->assertSame([20, 85.0, 1700.0, 'v-garlic', true], [$g['quantity'], $g['unit_cost'], $g['amount'], $g['variant_id'], $g['checked']]);
        $this->assertSame('Garlic Peanuts 250g', $g['description']);
        $this->assertSame([10, 150.0, 1500.0, 'v-cashew'], [$c['quantity'], $c['unit_cost'], $c['amount'], $c['variant_id']]);
        $this->assertSame([12, 60.0, 720.0, 'v-adobo'], [$a['quantity'], $a['unit_cost'], $a['amount'], $a['variant_id']]);
        $this->assertSame([5, 75.0, 375.0, 'v-brittle'], [$k['quantity'], $k['unit_cost'], $k['amount'], $k['variant_id']]);
    }

    public function test_totals_headers_and_noise_are_not_items(): void
    {
        $p = new ReceiptTextParser;
        foreach (['Brgy. 3, Calamba City 4027', 'Tel. No. 049-123-4567', 'Cashier: Jun 2', 'Page 1 of 1', 'Oct 7, 2026', '07 Oct 2026', '10/08/2026', 'TOTAL 1,200.00', 'VAT 12% 128.57', 'Cash 2000.00', 'Change 800.00', 'TIN 123-456-789', 'QTY DESCRIPTION AMOUNT', '------', '12345'] as $l) {
            $this->assertNull($p->parseLine($l), $l);
        }
    }

    public function test_second_sample_layout(): void
    {
        $r = (new ReceiptTextParser)->parse("BICOL CASHEW FARMS\nInvoice #: BCF-7781\nOct 7, 2026\nRoasted Cashew 100g  24  150.00  3,600.00\nKasoy Brittle x10 P60.00\nTOTAL 4,200.00",
            self::VARIANTS, self::SUPPLIERS);
        $this->assertSame(['BCF-7781', '2026-10-07', 4200.0, 's-bic'], [$r['invoice_no'], $r['invoice_date'], $r['total'], $r['supplier_id']]);
        $this->assertCount(2, $r['lines']);
        $this->assertEquals(4200, array_sum(array_map(fn ($l) => $l['quantity'] * $l['unit_cost'], $r['lines'])));
    }

    public function test_two_numbers_are_qty_and_amount(): void
    {
        $l = (new ReceiptTextParser)->parseLine('Honey Roasted Peanuts   24   2,160.00');
        $this->assertSame([24, 90.0, 2160.0], [$l['quantity'], $l['unit_cost'], $l['amount']]);
    }

    public function test_unknown_product_is_left_for_the_reviewer(): void
    {
        $r = (new ReceiptTextParser)->parse("Pistachio Imported  3  500.00  1500.00", self::VARIANTS);
        $this->assertNull($r['lines'][0]['variant_id']);
        $this->assertSame(3, $r['lines'][0]['quantity']);
    }

    public function test_fuzzy_match_survives_ocr_typos(): void
    {
        [$id] = (new ReceiptTextParser)->bestMatch('Garlc Peanut5 250g', self::VARIANTS, 'label');
        $this->assertSame('v-garlic', $id);
    }

    public function test_other_date_formats(): void
    {
        $p = new ReceiptTextParser;
        $this->assertSame('2026-10-08', $p->invoiceDate('Date: Oct 8, 2026'));
        $this->assertSame('2026-10-08', $p->invoiceDate('08-Oct-2026'));
        $this->assertSame('2026-10-08', $p->invoiceDate('2026-10-08'));
        $this->assertSame('2026-09-25', $p->invoiceDate('25/09/2026'));   // impossible as m/d, read as d/m
        $this->assertNull($p->invoiceDate('no date here'));
    }

    public function test_invoice_number_variants(): void
    {
        $p = new ReceiptTextParser;
        $this->assertSame('SI-2026-118', $p->invoiceNo("Invoice #: SI-2026-118"));
        $this->assertSame('88123', $p->invoiceNo("OR No. 88123"));
        $this->assertNull($p->invoiceNo('nothing'));
    }

    public function test_empty_text(): void
    {
        $r = (new ReceiptTextParser)->parse('');
        $this->assertSame([], $r['lines']);
        $this->assertNull($r['invoice_no']);
    }
}
