<?php

namespace Tests\Support;

use App\Services\Platform;

/**
 * TEST-ONLY stand-in for App\Services\Platform, used with DATA_SOURCE=mock (tests/TestCase.php).
 * The branches below are fixtures for the fake data in MockDataSource; they never reach the
 * website.
 */
class MockPlatform extends Platform
{
    public const BRANCHES = [
        ['id' => 'branch-calamba', 'name' => 'Calamba Branch', 'daily_target' => 6000],
        ['id' => 'branch-los-banos', 'name' => 'Los Baños Branch', 'daily_target' => 5000],
        ['id' => 'branch-santa-cruz', 'name' => 'Santa Cruz Branch', 'daily_target' => 4500],
    ];

    /** Test fixture settings (the real ones come from public.get_business_settings()). */
    public const SETTINGS = [
        'restock_threshold_default' => 20, 'stock_low_ratio' => 0.4, 'stock_plenty_ratio' => 0.8,
        'sales_low_ratio' => 0.7, 'sales_high_ratio' => 1.0, 'default_daily_sales_target' => null,
        'healthy_margin_percent' => 50, 'carried_over' => false, 'branches' => [],
    ];

    public function settings(): array
    {
        return self::SETTINGS;
    }

    public function isSupabase(): bool
    {
        return false;
    }

    public function branches(): array
    {
        return self::BRANCHES;
    }

    public function paymentMethods(): array
    {
        return ['gcash', 'maya', 'card', 'cod'];
    }

    public function cashMethod(): string
    {
        return 'cod';
    }
}
