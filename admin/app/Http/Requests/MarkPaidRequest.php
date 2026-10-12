<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/**
 * "Mark as paid" for a cash order: no free input. The confirmation happens in
 * the page's modal (data-confirm), so the form posts no field at all.
 */
class MarkPaidRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        // `accepted` is an implicit rule: it fails on a MISSING field even with
        // `nullable`, which refused every real click. `sometimes` checks it
        // only when a client actually sends `confirm`.
        return ['confirm' => ['sometimes', 'accepted']];
    }
}
