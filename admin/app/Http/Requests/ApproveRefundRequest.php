<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class ApproveRefundRequest extends FormRequest
{
    public function authorize(): bool { return true; } // route already requires role:admin

    public function rules(): array
    {
        return [
            // Optional: partial refund amount. Defaults to the full paid amount if left blank.
            'amount' => ['nullable', 'integer', 'min:1'],
            'note' => ['nullable', 'string', 'max:500'], // used for COD manual refunds
        ];
    }
}
