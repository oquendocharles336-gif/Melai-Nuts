<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class RejectRefundRequest extends FormRequest
{
    public function authorize(): bool { return true; }

    public function rules(): array
    {
        return ['reason' => ['required', 'string', 'min:5', 'max:500']];
    }

    public function messages(): array
    {
        return ['reason.required' => 'A written reason is required to reject a refund.'];
    }
}
