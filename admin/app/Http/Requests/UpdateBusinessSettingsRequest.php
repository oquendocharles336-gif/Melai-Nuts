<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** Owner business settings (thresholds and targets). Route requires role:admin; the database re-checks owner. */
class UpdateBusinessSettingsRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'restock_threshold_default' => Rules::quantity(0, 100000, false),
            'stock_low_percent' => ['nullable', 'numeric', 'gt:0', 'lt:100', 'decimal:0,2'],
            'stock_plenty_percent' => ['nullable', 'numeric', 'gt:0', 'max:100', 'decimal:0,2'],
            'sales_low_percent' => ['nullable', 'numeric', 'gt:0', 'max:1000', 'decimal:0,2'],
            'sales_high_percent' => ['nullable', 'numeric', 'gt:0', 'max:1000', 'decimal:0,2'],
            'default_daily_sales_target' => ['nullable', 'numeric', 'gt:0', 'max:100000000', 'decimal:0,2'],
            'healthy_margin_percent' => ['nullable', 'numeric', 'gt:0', 'lt:100', 'decimal:0,2'],
            'expiry_alert_days' => Rules::quantity(1, 365, false),
            'low_stock_badge_qty' => Rules::quantity(1, 1000, false),
        ];
    }

    public function messages(): array
    {
        return Rules::messages();
    }
}
