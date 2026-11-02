<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** The owner's fallback when HitPay's confirmation never arrived: the reason is logged. */
class ConfirmOnlinePaymentRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'reason' => ['required', 'string', 'min:10', 'max:300'],
            'reference' => ['nullable', 'string', 'max:100'],
        ];
    }
}
