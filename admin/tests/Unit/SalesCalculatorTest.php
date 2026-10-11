<?php

namespace Tests\Unit;

use App\Support\SalesCalculator;
use PHPUnit\Framework\TestCase;

/** Net sales come from the database (sales_overview); only the target rating is computed here. */
class SalesCalculatorTest extends TestCase
{
    public function test_status_thresholds(): void
    {
        $this->assertSame('low', SalesCalculator::status(600, 1000, 0.7, 1.0));
        $this->assertSame('average', SalesCalculator::status(700, 1000, 0.7, 1.0));
        $this->assertSame('average', SalesCalculator::status(1000, 1000, 0.7, 1.0));
        $this->assertSame('high', SalesCalculator::status(1001, 1000, 0.7, 1.0));
    }
}
