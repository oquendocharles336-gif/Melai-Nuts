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
