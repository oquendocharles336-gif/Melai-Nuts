<?php

namespace App\Http\Requests;

use App\Services\ActivityLogger;
use Illuminate\Auth\Events\Lockout;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

class LoginRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    protected function prepareForValidation(): void
    {
        if (is_string($this->input('email'))) {
            $this->merge(['email' => Str::lower(trim($this->input('email')))]);
        }
    }

    public function rules(): array
    {
        return [
            'email' => ['required', 'string', 'email', 'max:255'],
            'password' => ['required', 'string'],
        ];
    }

    public function messages(): array
    {
        return ['email.required' => 'Email is required.', 'password.required' => 'Password is required.'];
    }

    /**
     * Local-password sign-in, only for website logins that are NOT bound to a Firebase account
     * (legacy logins). Firebase-bound logins sign in only through Firebase.
     */
    public function authenticateLocally(): bool
    {
        return Auth::attempt([
            'email' => $this->input('email'),
            'password' => $this->input('password'),
            fn ($q) => $q->whereNull('firebase_uid'),
        ], $this->boolean('remember'));
    }

    public function failed(string $message = 'Invalid email or password.'): never
    {
        RateLimiter::hit($this->throttleKey(), config('melai.login.decay_seconds'));

        throw ValidationException::withMessages(['auth' => $message]);
    }

    public function succeeded(): void
    {
        RateLimiter::clear($this->throttleKey());
    }

    public function ensureIsNotRateLimited(): void
    {
        if (! RateLimiter::tooManyAttempts($this->throttleKey(), config('melai.login.max_attempts'))) {
            return;
        }

        event(new Lockout($this));
        ActivityLogger::log('auth.lockout', 'Too many login attempts for '.$this->input('email'));
        $seconds = RateLimiter::availableIn($this->throttleKey());

        throw ValidationException::withMessages([
            'auth' => "Too many login attempts. Please try again in {$seconds} seconds.",
        ]);
    }

    protected function throttleKey(): string
    {
        return Str::transliterate(Str::lower($this->input('email')).'|'.$this->ip());
    }
}
