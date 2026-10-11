<?php

namespace App\Http\Requests;

use App\Models\User;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Str;

/** Used when an ADMIN creates a staff account directly (not self-registration). */
class AdminCreateUserRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true; // route already requires role:admin
    }

    protected function prepareForValidation(): void
    {
        $name = $this->input('name');
        $email = $this->input('email');

        $this->merge([
            'name' => is_string($name) ? trim(preg_replace('/\s+/', ' ', $name)) : $name,
            'email' => is_string($email) ? Str::lower(trim($email)) : $email,
        ]);
    }

    public function rules(): array
    {
        return [
            // Same rules as the app (lib/core/utils/validation_utils.dart) — see Rules.
            'name' => Rules::name(),
            'email' => [...Rules::email(), 'unique:users,email'],
            'role' => ['required', 'in:'.User::ROLE_STAFF],
            'password' => Rules::newPassword($this->input('email'), $this->input('name')),
            'password_confirmation' => ['required', 'same:password'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + [
            'name.required' => 'Full name is required.',
            'email.unique' => 'An account with this email already exists.',
            'role.in' => 'Website accounts created here are staff accounts. Riders are created in the Melai Nuts app.',
            'password_confirmation.same' => 'Passwords do not match.',
        ];
    }
}
