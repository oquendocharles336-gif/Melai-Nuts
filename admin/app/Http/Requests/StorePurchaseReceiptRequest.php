<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** New purchase receipt (photo + OCR text). */
class StorePurchaseReceiptRequest extends FormRequest
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
            'photo' => ['nullable', 'file', 'mimes:jpg,jpeg,png,webp', 'max:8192'],
            'ocr_text' => ['nullable', 'string', 'max:20000'],
            'ocr_confidence' => ['nullable', 'numeric', 'min:0', 'max:100'],
        ];
    }
}
