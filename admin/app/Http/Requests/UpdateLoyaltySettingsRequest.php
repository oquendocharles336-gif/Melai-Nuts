<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class UpdateLoyaltySettingsRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'earn_pesos_per_point' => ['required', 'numeric', 'min:1', 'max:100000', 'decimal:0,2'],
            'points_per_peso' => ['required', 'numeric', 'gt:0', 'max:10000', 'decimal:0,4'],
            'max_discount_percent' => ['required', 'numeric', 'gt:0', 'max:100', 'decimal:0,2'],
        ];
    }

    public function messages(): array
    {
        return [
            'earn_pesos_per_point.min' => 'Earn rate must be at least PHP 1 per point.',
            'points_per_peso.gt' => 'Redeem rate must be more than 0 points per peso.',
            'max_discount_percent.max' => 'Maximum discount cannot be more than 100%.',
        ] + Rules::messages();
    }
}
