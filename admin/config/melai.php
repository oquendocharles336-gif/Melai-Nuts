<?php

return [
    // First admin, created by `php artisan db:seed`. There are NO default credentials: the seeder
    // refuses to run until ADMIN_EMAIL and ADMIN_PASSWORD are set in .env (no demo account).
    'admin' => [
        'name'     => env('ADMIN_NAME', 'Melai Admin'),
        'email'    => env('ADMIN_EMAIL'),
        'password' => env('ADMIN_PASSWORD'),
        // Firebase UID of the owner's row in Supabase staff_members (the standard setup). The admin
        // login acts as this owner: `php artisan db:seed` and every sign-in link it automatically
        // after Supabase confirms an ACTIVE OWNER with the same email. Empty: the active owner row
        // whose email equals ADMIN_EMAIL is used instead.
        'staff_uid' => env('ADMIN_STAFF_UID'),
    ],
    // Login rate limit (per email + IP)
    'login' => ['max_attempts' => 5, 'decay_seconds' => 60],

    // Business data ALWAYS comes from the mobile app's real Supabase database. There is no demo /
    // mock option on the website (the automated tests bind their own fixtures from admin/tests/).

    'supabase' => [
        'connection' => 'supabase',             // config/database.php connection name
        'order_window_days' => (int) env('SUPABASE_ORDER_WINDOW_DAYS', 90), // Payments/Refunds lists
    ],

    // Dashboard: database answers are cached this many seconds per app account (30-60 is sensible;
    // 0 turns the cache off). The account's status is still checked on every request.
    'dashboard' => ['cache_seconds' => (int) env('DASHBOARD_CACHE_SECONDS', 45)],

    // All users page (admin/users): customers loaded per view, newest first. A search reaches the
    // rest. The database caps it at 2000.
    'users_customer_limit' => (int) env('USERS_CUSTOMER_LIMIT', 500),

    // Stale-while-revalidate (App\Support\Swr): after the fresh time above, a cached answer is still
    // shown at once for up to stale_seconds while the browser fetches the new one in the background.
    // Reports cover whole past days, so they stay fresh longer. Any change made through this website
    // invalidates everything immediately.
    'cache' => [
        'stale_seconds' => (int) env('MELAI_CACHE_STALE_SECONDS', 300),
        'reports_seconds' => (int) env('MELAI_REPORTS_CACHE_SECONDS', 120),
    ],

    // TEMPORARY: Server-Timing header + storage/logs/timing.log per request (supabase calls / ms).
    'timing' => filter_var(env('MELAI_TIMING', false), FILTER_VALIDATE_BOOL),

    // CHANGE: sales thresholds. net / target below low_below = Low, above high_above = High, else Average.
    'sales' => ['low_below' => 0.7, 'high_above' => 1.0],

    // CHANGE: stock thresholds (total stock / par level). Below low_below = Low, from plenty_from = Plenty.
    // With Supabase there is no par level, so the ratio is "share of items above their restock threshold".
    'stock' => ['low_below' => 0.4, 'plenty_from' => 0.8],

    // Optional daily SALES TARGETS per branch, matched to the app's branches by NAME
    // (case-insensitive). The owner sets these; none are invented. A branch without a target
    // shows its real sales with "No target set" instead of a Low/Average/High rating.
    //   'targets' => ['Calamba Branch' => 6000, ...]
    'targets' => [],
    // Target for any branch not listed above; leave DEFAULT_DAILY_TARGET empty for none.
    'default_daily_target' => env('DEFAULT_DAILY_TARGET') !== null && env('DEFAULT_DAILY_TARGET') !== ''
        ? (float) env('DEFAULT_DAILY_TARGET') : null,

    // Sidebar pages (slug => title). All of them show live data from the app's database.
    'sections' => [
        'sales' => 'Sales', 'products' => 'Products', 'inventory' => 'Inventory',
        'cash-drawer' => 'Cash Drawer', 'reports' => 'Reports',
    ],
];
