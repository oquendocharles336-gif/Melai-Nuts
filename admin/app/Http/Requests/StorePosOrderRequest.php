<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** In-store sale recorded from the website. Delivery orders can never be created here. */
class StorePosOrderRequest extends FormRequest
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
            'items' => ['required', 'array', 'min:1', 'max:50'],
            'items.*.variant_id' => ['required', 'uuid'],
            'items.*.quantity' => Rules::quantity(1, 1000),
            'method' => ['required', 'in:cash,gcash,card'],
            'reference' => ['nullable', 'string', 'min:4', 'max:80', 'regex:/^[A-Za-z0-9\-]+$/', 'required_unless:method,cash'],
            'cash_received' => ['nullable', 'numeric', 'min:0', 'max:10000000', 'decimal:0,2'],
            'key' => ['required', 'string', 'max:100'],
            'type' => ['prohibited'], 'order_type' => ['prohibited'], 'is_delivery' => ['prohibited'],
            'delivery_address' => ['prohibited'], 'delivery_address_id' => ['prohibited'], 'fulfillment' => ['prohibited'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + ['reference.regex' => 'The reference uses letters, digits and dashes only.'];
    }
}
