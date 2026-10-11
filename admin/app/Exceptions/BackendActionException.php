<?php

namespace App\Exceptions;

use RuntimeException;

/**
 * The shared database refused a request on purpose (a business rule or permission check
 * inside a Supabase function, e.g. "Only an active owner can do this."). The message is
 * written for people and is safe to show on screen.
 */
class BackendActionException extends RuntimeException {}
