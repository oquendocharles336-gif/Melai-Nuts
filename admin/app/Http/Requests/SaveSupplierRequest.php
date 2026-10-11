<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

/** Add / edit a supplier. The phone is stored in the one phone format (E.164) when it is a mobile. */
class SaveSupplierRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    protected function prepareForValidation(): void
    {
        $name = $this->input('name');
        if (is_string($name)) {
            $this->merge(['name' => trim(preg_replace('/\s+/', ' ', $name))]);
        }
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'min:2', 'max:120'],
            'contact_person' => array_merge(Rules::name(false), []),
            'phone' => ['nullable', 'string', 'max:20', 'regex:/^[0-9+() .\-]+$/'],
            'email' => Rules::email(false),
            'address' => Rules::text(250),
            'tin' => ['nullable', 'string', 'max:20', 'regex:/^[0-9\-]+$/'],
            'is_active' => ['nullable', 'boolean'],
        ];
    }

    /** @return array<string, mixed> */
    public function validated($key = null, $default = null)
    {
        $data = parent::validated($key, $default);
        if ($key === null && array_key_exists('phone', $data)) {
            $data['phone'] = Rules::normalizePhone($data['phone']);
        }

        return $data;
    }

    public function messages(): array
    {
        return [
            'contact_person.regex' => 'Contact person should only contain letters, spaces, hyphens, apostrophes or periods.',
            'phone.regex' => 'Use digits, spaces, +, -, ( and ) only.',
            'tin.regex' => 'TIN uses digits and dashes only (e.g. 123-456-789-000).',
        ] + Rules::messages();
    }
}
