<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class ActivityLog extends Model
{
    public $timestamps = false; // created_at is set by the database

    protected $fillable = ['user_id', 'action', 'description', 'meta', 'ip_address'];
    protected $casts = ['meta' => 'array', 'created_at' => 'datetime'];

    public function user()
    {
        return $this->belongsTo(User::class);
    }
}
