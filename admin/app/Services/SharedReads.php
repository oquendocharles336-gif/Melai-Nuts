<?php

namespace App\Services;

use App\Contracts\DataSource;
use App\Support\Swr;

/**
 * Reads several pages need, cached once per account (App\Support\Swr) instead of once per page:
 * stock per branch (Overview, dashboard, Stock page, sidebar badge). Same data, same scoping
 * (the database limits it to the account's branches), just not re-read on every tab.
 */
class SharedReads
{
    public function __construct(private DataSource $data) {}

    /** DataSource::stock(): [branch id => items]. */
    public function stock(): array
    {
        return Swr::remember('stock', Swr::fresh(), Swr::stale(), fn () => $this->data->stock());
    }

    /** Reads to add to a batched prefetch when the cached stock is missing. */
    public function stockReads(): array
    {
        return Swr::has('stock') ? [] : [['stock', []]];
    }
}
