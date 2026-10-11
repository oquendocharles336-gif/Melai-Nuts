<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** Edit / approve a purchase receipt and its lines. */
class UpdatePurchaseReceiptRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'branch_id' => ['required', 'uuid'],
            'supplier_id' => ['nullable', 'uuid'],
            'supplier_invoice_no' => ['nullable', 'string', 'max:40'],
            'invoice_date' => ['nullable', 'date_format:Y-m-d', 'before_or_equal:today'],
            'invoice_total' => ['nullable', 'numeric', 'min:0', 'max:100000000', 'decimal:0,2'],
            'notes' => Rules::text(500),
            'lines' => ['array', 'max:200'],
            'lines.*.raw_text' => ['nullable', 'string', 'max:500'],
            'lines.*.description' => ['nullable', 'string', 'max:200'],
            'lines.*.variant_id' => ['nullable', 'uuid'],
            'lines.*.quantity' => Rules::quantity(1, 100000, false),
            'lines.*.unit_cost' => ['nullable', 'numeric', 'min:0', 'max:1000000', 'decimal:0,2'],
            'lines.*.batch_code' => ['nullable', 'string', 'max:40'],
            // Stock being received cannot already be expired.
            'lines.*.expiration_date' => ['nullable', 'date_format:Y-m-d', 'after:today'],
            'action' => ['nullable', 'in:save,approve'],
            'request_key' => ['nullable', 'string', 'min:8', 'max:100'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + [
            'invoice_date.before_or_equal' => 'The invoice date cannot be in the future.',
            'lines.*.expiration_date.after' => 'The expiration date must be after today.',
        ];
    }
}
