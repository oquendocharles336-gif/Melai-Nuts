<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

/** Manual admin add/deduct of a member's points — route already requires role:admin. */
class AdjustLoyaltyPointsRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            // Whole number, non-zero; the "cannot exceed the current balance" check is done by the
            // database (owner_adjust_loyalty_points), which knows the member's actual balance.
            'points' => ['required', 'integer', Rule::notIn([0])],
            'reason' => ['required', 'string', 'min:3', 'max:255'],
        ];
    }

    public function messages(): array
    {
        return [
            'points.required' => 'Enter how many points to add or deduct.',
            'points.integer' => 'Points must be a whole number.',
            'points.not_in' => 'Points cannot be zero.',
            'reason.required' => 'A reason is required for a manual adjustment.',
        ];
    }
}
