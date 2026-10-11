<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** Receive a batch from the website. Same rules as the app's Receive Stock screen. */
class ReceiveStockRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    protected function prepareForValidation(): void
    {
        // Same order as before: "no app database" (503) is reported before field errors.
        abort_unless(app(\App\Services\Platform::class)->isSupabase(), 503, 'This action needs the Melai Nuts app database.');
    }

    public function rules(): array
    {
        return [
            'branch' => ['required', 'string', 'max:64'],
            'variant_id' => ['required', 'uuid'],
            'quantity' => Rules::quantity(1, 100000),
            'batch_code' => Rules::text(40, 1, true),
            // Received stock cannot already be expired.
            'expiration_date' => ['required', 'date_format:Y-m-d', 'after:today'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + ['expiration_date.after' => 'The expiration date must be after today.'];
    }
}
