<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Str;
use Illuminate\Validation\Rules\Password;

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
            'name' => ['required', 'string', 'min:2', 'max:100'],
            'email' => ['required', 'string', 'email:rfc', 'max:255', 'unique:users,email'],
            'password' => ['required', 'string', Password::min(8)->mixedCase()->numbers()->symbols()],
            'password_confirmation' => ['required', 'same:password'],
        ];
    }

    public function messages(): array
    {
        return [
            'name.required' => 'Full name is required.',
            'email.unique' => 'An account with this email already exists.',
            'password_confirmation.required' => 'Please confirm your password.',
            'password_confirmation.same' => 'Passwords do not match.',
        ];
    }
}
