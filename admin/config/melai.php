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
    // Security headers (App\Http\Middleware\SecurityHeaders). HSTS is only sent over HTTPS.
    'security' => [
        'csp' => (bool) env('SECURITY_CSP', true),
        'hsts' => (bool) env('SECURITY_HSTS', true),
        // Refunds and points adjustments ask for the password again after this many seconds.
        'password_confirm_seconds' => (int) env('PASSWORD_CONFIRM_SECONDS', 300),
    ],

    'cache' => [
        'stale_seconds' => (int) env('MELAI_CACHE_STALE_SECONDS', 300),
        'reports_seconds' => (int) env('MELAI_REPORTS_CACHE_SECONDS', 120),
    ],

    // TEMPORARY: Server-Timing header + storage/logs/timing.log per request (supabase calls / ms).
    'timing' => filter_var(env('MELAI_TIMING', false), FILTER_VALIDATE_BOOL),

    // Sales targets, sales-rating ratios, stock-health ratios, the restock threshold fallback and the
    // healthy-margin line are OWNER SETTINGS in the database (Settings > Business settings,
    // public.get_business_settings / owner_update_business_settings). Nothing here: a value the owner
    // has not set is shown as "Not set", never replaced by a number from this file.

    // Sidebar pages (slug => title). All of them show live data from the app's database.
    'sections' => [
        'sales' => 'Sales', 'products' => 'Products', 'inventory' => 'Inventory',
        'cash-drawer' => 'Cash Drawer', 'reports' => 'Reports',
    ],
];
