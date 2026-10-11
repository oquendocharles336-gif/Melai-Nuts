<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Mailgun, Postmark, AWS and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

    // Firebase Authentication of the Melai Nuts app (project in ../.firebaserc). The website signs
    // people in with their app account through the Identity Toolkit REST API and verifies the ID
    // tokens itself (App\Services\Firebase). The Web API key is a public project identifier, not a
    // secret, but keep it out of Git anyway. No service-account key is used.
    'firebase' => [
        'web_api_key' => env('FIREBASE_WEB_API_KEY'),
        'project_id' => env('FIREBASE_PROJECT_ID'),
        // true = refuse website sign-in until Firebase reports the email as verified.
        'require_verified_email' => (bool) env('FIREBASE_REQUIRE_VERIFIED_EMAIL', false),
    ],

    // HitPay Refund API: sends approved online refunds back to the
    // customer's GCash / Maya / card. Leave HITPAY_API_KEY empty to keep refunding by hand.
    'hitpay' => [
        'api_key' => env('HITPAY_API_KEY'),
        'env' => env('HITPAY_ENV', 'sandbox'),   // 'live' or 'sandbox'
        'timeout' => (int) env('HITPAY_TIMEOUT', 25),
    ],

];
