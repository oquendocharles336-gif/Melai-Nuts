<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Str;

class RegisterRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
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
            'password' => Rules::newPassword($this->input('email'), $this->input('name')),
            'password_confirmation' => ['required', 'same:password'],
            // An active choice: the box is never pre-ticked (resources/views/auth/register.blade.php).
            'terms' => ['accepted'],
        ];
    }

    public function messages(): array
    {
        return Rules::messages() + [
            'name.required' => 'Full name is required.',
            'email.unique' => 'An account with this email already exists.',
            'password_confirmation.required' => 'Please confirm your password.',
            'password_confirmation.same' => 'Passwords do not match.',
            'terms.accepted' => 'Please tick the box to agree to the Terms and Conditions and the Privacy Policy.',
        ];
    }
}
