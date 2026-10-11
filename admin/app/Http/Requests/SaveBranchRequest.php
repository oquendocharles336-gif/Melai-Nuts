<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** Add / edit a branch. Same limits as the branches CHECK constraints. */
class SaveBranchRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    protected function prepareForValidation(): void
    {
        $name = $this->input('name');
        if (is_string($name)) {
            $this->merge(['name' => trim(preg_replace('/\s+/', ' ', $name))]);
        }
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'min:2', 'max:80'],
            'address' => Rules::text(300),
            // Branch numbers are often landlines, so any phone characters are accepted here.
            'contact_phone' => ['nullable', 'string', 'max:40', 'regex:/^[0-9+() .\-]+$/'],
            'operating_hours' => Rules::text(120),
            'delivery_fee' => Rules::money(true, 0, 100000),
            'daily_sales_target' => ['nullable', 'numeric', 'gt:0', 'max:100000000', 'decimal:0,2'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + [
            'delivery_fee.required' => 'Enter the delivery fee (0 if delivery is free).',
            'contact_phone.regex' => 'Use digits, spaces, +, -, ( and ) only.',
        ];
    }
}
