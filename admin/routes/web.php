<?php

use App\Http\Controllers\ActivityLogController;
use App\Http\Controllers\Admin\BusinessSettingsController;
use App\Http\Controllers\Admin\ProfitReportController;
use App\Http\Controllers\Auth\TwoFactorController;
use App\Http\Controllers\Admin\LoyaltyController;
use App\Http\Controllers\Admin\PaymentController;
use App\Http\Controllers\Admin\RefundController;
use App\Http\Controllers\Admin\UserController;
use App\Http\Controllers\Auth\LoginController;
use App\Http\Controllers\Auth\WaitingController;
use App\Http\Controllers\DashboardController;
use App\Http\Controllers\LoyaltyCardController;
use App\Http\Controllers\OperationsController;
use App\Http\Controllers\OrdersController;
use App\Http\Controllers\OverviewController;
use App\Http\Controllers\PurchaseReceiptController;
use App\Http\Controllers\ReportsController;
use App\Http\Controllers\Shop\CartController as ShopCartController;
use App\Http\Controllers\Shop\CheckoutController as ShopCheckoutController;
use App\Http\Controllers\Shop\CustomerAuthController;
use App\Http\Controllers\Shop\OrderController as ShopOrderController;
use App\Http\Controllers\Shop\StorefrontController;
use App\Http\Controllers\StockController;
use Illuminate\Support\Facades\Route;

// Terms and Privacy Policy: readable by everyone, signed in or not (same text as the app).
Route::view('/terms', 'legal.terms')->name('legal.terms');
Route::view('/privacy', 'legal.privacy')->name('legal.privacy');

// ---------------------------------------------------------------------------------------------
// Customer shop: public at "/". Customers sign in with their Melai Nuts app account (Firebase) and
// get their OWN session (App\Services\Shop\CustomerSession), never an admin login.
// ---------------------------------------------------------------------------------------------
Route::name('shop.')->group(function () {
    Route::get('/', [StorefrontController::class, 'home'])->name('home');

    Route::prefix('shop')->group(function () {
        Route::get('/search', [StorefrontController::class, 'search'])->name('search');
        Route::get('/p/{product}', [StorefrontController::class, 'product'])->name('product')->where('product', '[0-9A-Za-z-]{1,64}');
        Route::post('/branch', [StorefrontController::class, 'locate'])->name('branch')->middleware('throttle:20,1');

        Route::middleware('shop.buyer')->group(function () {
            Route::get('/cart', [ShopCartController::class, 'show'])->name('cart');
            Route::post('/cart', [ShopCartController::class, 'add'])->name('cart.add')->middleware('throttle:60,1');
            Route::patch('/cart/{variant}', [ShopCartController::class, 'update'])->name('cart.update')->middleware('throttle:60,1');
        });

        // Everyone signs in on the single login page (/login); this old address forwards there.
        Route::get('/login', [CustomerAuthController::class, 'showLogin'])->name('login');
        Route::get('/register', [CustomerAuthController::class, 'showRegister'])->name('register');
        Route::post('/register', [CustomerAuthController::class, 'register'])->middleware('throttle:5,1');
        Route::get('/verify-email', [CustomerAuthController::class, 'showVerify'])->name('verify');
        Route::post('/verify-email', [CustomerAuthController::class, 'checkVerified'])->name('verify.check')->middleware('throttle:10,1');
        Route::post('/verify-email/resend', [CustomerAuthController::class, 'resend'])->name('verify.resend')->middleware('throttle:3,1');
        Route::post('/verify-email/cancel', [CustomerAuthController::class, 'cancelSignUp'])->name('verify.cancel');
        Route::get('/forgot-password', [CustomerAuthController::class, 'showForgot'])->name('forgot');
        Route::post('/forgot-password', [CustomerAuthController::class, 'forgot'])->middleware('throttle:5,1');
        Route::post('/logout', [CustomerAuthController::class, 'logout'])->name('logout');

        Route::middleware(['shop.buyer', 'customer'])->group(function () {
            Route::post('/cart/voucher', [ShopCartController::class, 'voucher'])->name('cart.voucher')->middleware('throttle:10,1');
            Route::delete('/cart/voucher', [ShopCartController::class, 'removeVoucher'])->name('cart.voucher.remove');
            Route::post('/cart/points', [ShopCartController::class, 'points'])->name('cart.points');
            Route::get('/checkout', [ShopCheckoutController::class, 'show'])->name('checkout');
            Route::post('/checkout', [ShopCheckoutController::class, 'place'])->name('checkout.place')->middleware('throttle:10,1');
            Route::get('/orders', [ShopOrderController::class, 'index'])->name('orders');
            Route::get('/orders/{order}', [ShopOrderController::class, 'show'])->name('orders.show')->where('order', '[0-9A-Za-z-]{1,64}');
            Route::get('/orders/{order}/status.json', [ShopOrderController::class, 'status'])->name('orders.status')->where('order', '[0-9A-Za-z-]{1,64}');
            Route::post('/orders/{order}/pay', [ShopOrderController::class, 'pay'])->name('orders.pay')->where('order', '[0-9A-Za-z-]{1,64}')->middleware('throttle:10,1');
            Route::get('/payment/return', [ShopOrderController::class, 'paymentReturn'])->name('payment.return');
            Route::get('/points', [ShopOrderController::class, 'points'])->name('points');
            Route::get('/account', [CustomerAuthController::class, 'account'])->name('account');
            Route::get('/terms-update', [CustomerAuthController::class, 'showTerms'])->name('terms');
            Route::post('/terms-update', [CustomerAuthController::class, 'acceptTerms']);
        });
    });
});

// ---------------------------------------------------------------------------------------------
// Admin website (the owner only: staff use the Melai Nuts app). Customers never get past `no.customers` + `auth`.
// ---------------------------------------------------------------------------------------------
// Sign-in addresses (logged-in admins are redirected to the dashboard). There are no sign-in pages:
// each address opens its panel on the shop homepage (App\Support\AuthPanel); the POSTs do the work.
Route::middleware('guest')->group(function () {
    Route::get('/login', [LoginController::class, 'create'])->name('login');
    Route::post('/login', [LoginController::class, 'store']);
    Route::redirect('/forgot-password', '/?panel=reset-password')->name('password.request');   // the reset panel on the homepage
    Route::post('/forgot-password', [LoginController::class, 'forgot'])->name('password.email')->middleware('throttle:5,1');
});

Route::middleware(['no.customers', 'auth', 'active', 'bumps.cache', 'two.factor'])->group(function () {
    Route::post('/logout', [LoginController::class, 'destroy'])->name('logout');

    // Optional two-step sign-in (TOTP). The challenge is the only page open before the code.
    Route::get('/two-factor/challenge', [TwoFactorController::class, 'challenge'])->name('two-factor.challenge');
    Route::post('/two-factor/challenge', [TwoFactorController::class, 'verify'])->name('two-factor.verify')->middleware('throttle:10,1');
    Route::get('/two-factor', [TwoFactorController::class, 'show'])->name('two-factor.show');
    Route::post('/two-factor', [TwoFactorController::class, 'start'])->name('two-factor.start')->middleware('throttle:10,1');
    Route::post('/two-factor/confirm', [TwoFactorController::class, 'confirm'])->name('two-factor.confirm')->middleware('throttle:10,1');
    Route::delete('/two-factor', [TwoFactorController::class, 'disable'])->name('two-factor.disable')->middleware('throttle:10,1');

    Route::get('/waiting', [WaitingController::class, 'waiting'])->name('waiting');
    Route::post('/waiting/verify-email', [WaitingController::class, 'resendVerification'])->name('waiting.verify-email')->middleware('throttle:3,1');

    // Admin-only: staff get 403, even without access
    Route::middleware('role:admin')->prefix('admin')->name('admin.')->group(function () {
        Route::get('/activity-logs', [ActivityLogController::class, 'index'])->name('logs');
        Route::get('/activity-logs/export', [ActivityLogController::class, 'export'])->name('logs.export');

        Route::get('/users', [UserController::class, 'index'])->name('users.index');
        Route::get('/users/create', [UserController::class, 'create'])->name('users.create');
        Route::post('/users', [UserController::class, 'store'])->name('users.store');
        Route::post('/users/{user}/toggle-access', [UserController::class, 'toggleAccess'])->name('users.toggle-access');
        Route::post('/users/{user}/toggle-active', [UserController::class, 'toggleActive'])->name('users.toggle-active');
        Route::post('/users/{user}/link', [UserController::class, 'link'])->name('users.link');       // Supabase mode
        Route::post('/users/{user}/unlink', [UserController::class, 'unlink'])->name('users.unlink'); // Supabase mode
        Route::post('/users/{user}/approve', [UserController::class, 'approve'])->name('users.approve')->middleware('throttle:20,1'); // Supabase mode
        Route::post('/app-accounts/{uid}/active', [UserController::class, 'setAppActive'])->name('users.app-active')->middleware('throttle:30,1'); // disable / enable a staff or customer app account

        Route::get('/payments', [PaymentController::class, 'index'])->name('payments.index');
        Route::get('/payments/export', [PaymentController::class, 'export'])->name('payments.export');
        Route::post('/payments/{orderId}/mark-paid', [PaymentController::class, 'markPaid'])->name('payments.mark-paid')->middleware('password.recent');
        Route::post('/payments/{orderId}/confirm-online', [PaymentController::class, 'confirmOnline'])->name('payments.confirm-online')->middleware('password.recent');

        Route::get('/refunds', [RefundController::class, 'index'])->name('refunds.index');
        Route::get('/refunds/export', [RefundController::class, 'export'])->name('refunds.export');
        Route::post('/refunds/{orderId}/approve', [RefundController::class, 'approve'])->name('refunds.approve')->middleware('password.recent');
        Route::post('/refunds/{orderId}/reject', [RefundController::class, 'reject'])->name('refunds.reject');
        Route::post('/refunds/{orderId}/complete', [RefundController::class, 'complete'])->name('refunds.complete')->middleware('password.recent'); // HitPay reference entered by hand
        Route::post('/refunds/{orderId}/hitpay', [RefundController::class, 'sendHitpay'])->name('refunds.hitpay')->middleware(['throttle:10,1', 'password.recent']);
        Route::post('/refunds/{orderId}/hitpay/check', [RefundController::class, 'checkHitpay'])->name('refunds.hitpay.check');
        Route::post('/refunds/{orderId}/hitpay/abandon', [RefundController::class, 'abandonHitpay'])->name('refunds.hitpay.abandon');

        Route::put('/loyalty/settings', [LoyaltyController::class, 'updateSettings'])->name('loyalty.settings.update');

        // Owner: profit by product option and inventory valuation (20261024000000), CSV and print.
        Route::get('/profit', [ProfitReportController::class, 'index'])->name('profit.index');
        Route::get('/profit/export/{section}', [ProfitReportController::class, 'export'])->name('profit.export');

        // Owner business settings and branch details (stored in the app's database; owner only there too).
        Route::get('/business-settings', [BusinessSettingsController::class, 'index'])->name('business.index');
        Route::put('/business-settings', [BusinessSettingsController::class, 'update'])->name('business.update')->middleware('throttle:20,1');
        Route::post('/branches', [BusinessSettingsController::class, 'saveBranch'])->name('branches.store')->middleware('throttle:20,1');
        Route::put('/branches/{branch}', [BusinessSettingsController::class, 'saveBranch'])->name('branches.update')->middleware('throttle:20,1');
        Route::post('/loyalty/{member}/adjust', [LoyaltyController::class, 'adjust'])->name('loyalty.adjust')->middleware('password.recent');
    });

    // Admin-only actions on the shared catalog (Supabase mode)
    Route::middleware(['role:admin', 'has.access'])->group(function () {
        Route::post('/products/{product}/toggle-active', [OperationsController::class, 'toggleProduct'])->name('ops.products.toggle');
    });

    // Needs granted access; new accounts are redirected to /waiting
    Route::middleware('has.access')->group(function () {
        // The old "Link my app account" page: linking now happens automatically at sign-in.
        Route::redirect('/account/link', '/dashboard')->name('account.link');
        Route::post('/account/link', fn () => redirect()->route('dashboard'));

        Route::get('/dashboard', [DashboardController::class, 'index'])->name('dashboard')->middleware('shell');

        // Redesigned admin UI: range-aware Overview numbers and the sidebar badges (read-only JSON).
        Route::get('/dashboard/overview.json', [OverviewController::class, 'overview'])->name('dashboard.overview');
        Route::get('/ui/counts.json', [OverviewController::class, 'counts'])->name('ui.counts');
        Route::get('/ui/pulse.json', [OverviewController::class, 'pulse'])->name('ui.pulse')->middleware('throttle:240,1');
        Route::get('/ui/search.json', [OverviewController::class, 'search'])->name('ui.search')->middleware('throttle:120,1');

        // Orders: list + drawer, "Move to next stage" and "New order" (the app's own staff functions).
        Route::get('/orders', [OrdersController::class, 'index'])->name('orders.index')->middleware('shell');
        Route::get('/orders/export', [OrdersController::class, 'export'])->name('orders.export');
        Route::get('/orders/branches.json', [OrdersController::class, 'branches'])->name('orders.branches');
        Route::get('/orders/catalog.json', [OrdersController::class, 'catalog'])->name('orders.catalog');
        Route::post('/orders', [OrdersController::class, 'store'])->name('orders.store')->middleware('throttle:20,1');
        Route::post('/orders/{order}/advance', [OrdersController::class, 'advance'])->name('orders.advance')->middleware('throttle:30,1');

        // Stock: receive a batch (staff_receive_batch; the app checks the 'inventory' permission).
        Route::post('/stock/receive', [StockController::class, 'receive'])->name('stock.receive')->middleware('throttle:20,1');

        Route::view('/settings', 'settings')->name('settings');
        // Settings > "Send me a reset email": a Firebase reset link to the signed-in person's own email.
        Route::post('/settings/password-reset', [LoginController::class, 'sendMyReset'])->name('settings.password-reset')->middleware('throttle:3,10');
        Route::view('/help', 'help')->name('help');
        Route::get('/loyalty', [LoyaltyController::class, 'index'])->name('loyalty.index');
        Route::get('/loyalty/{member}', [LoyaltyController::class, 'show'])->name('loyalty.show');
        Route::get('/s/{slug}', [DashboardController::class, 'section'])->name('section')->middleware('shell'); // live pages from the app's database

        // Reports and forecasting (Supabase mode; the database checks owner / 'view_reports').
        Route::middleware('supabase')->group(function () {
            Route::get('/reports/export', [ReportsController::class, 'export'])->name('reports.export');
            Route::get('/reports/forecast', [ReportsController::class, 'forecast'])->name('reports.forecast');
            Route::post('/reports/forecast', [ReportsController::class, 'saveForecast'])->name('reports.forecast.save')->middleware('throttle:20,1');
            Route::get('/reports/forecast/{run}', [ReportsController::class, 'forecastRun'])->name('reports.forecast.run');

            // RFID loyalty cards (the database checks staff / owner rights).
            Route::get('/cards', [LoyaltyCardController::class, 'index'])->name('cards.index');
            Route::post('/cards/tap', [LoyaltyCardController::class, 'tap'])->name('cards.tap')->middleware('throttle:60,1');
            Route::post('/cards/find', [LoyaltyCardController::class, 'find'])->name('cards.find')->middleware('throttle:30,1');
            Route::get('/cards/customer/{uid}', [LoyaltyCardController::class, 'customer'])->name('cards.customer');
            Route::post('/cards/customer/{uid}/register', [LoyaltyCardController::class, 'register'])->name('cards.register');
            Route::post('/cards/customer/{uid}/replace', [LoyaltyCardController::class, 'replace'])->name('cards.replace');
            Route::post('/cards/{card}/block', [LoyaltyCardController::class, 'block'])->name('cards.block');
            Route::post('/cards/{card}/unblock', [LoyaltyCardController::class, 'unblock'])->name('cards.unblock');

            // Suppliers and purchase receipts with OCR (owner, or staff with inventory permission).
            Route::get('/receipts', [PurchaseReceiptController::class, 'index'])->name('receipts.index');
            Route::get('/receipts/new', [PurchaseReceiptController::class, 'create'])->name('receipts.create');
            Route::post('/receipts', [PurchaseReceiptController::class, 'store'])->name('receipts.store')->middleware('throttle:20,1');
            Route::get('/receipts/{id}', [PurchaseReceiptController::class, 'show'])->name('receipts.show');
            Route::post('/receipts/{id}', [PurchaseReceiptController::class, 'update'])->name('receipts.update');
            Route::post('/receipts/{id}/cancel', [PurchaseReceiptController::class, 'cancel'])->name('receipts.cancel');
            Route::get('/receipts/{id}/image', [PurchaseReceiptController::class, 'image'])->name('receipts.image');
            Route::get('/suppliers', [PurchaseReceiptController::class, 'suppliers'])->name('suppliers.index');
            Route::post('/suppliers', [PurchaseReceiptController::class, 'saveSupplier'])->name('suppliers.store');
            Route::post('/suppliers/{id}', [PurchaseReceiptController::class, 'saveSupplier'])->name('suppliers.update');
        });
    });
});
