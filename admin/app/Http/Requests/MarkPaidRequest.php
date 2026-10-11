<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** "Mark as paid" for a cash order: no free input; the confirmation flag comes from the modal. */
class MarkPaidRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return ['confirm' => ['nullable', 'accepted']];
    }
}
