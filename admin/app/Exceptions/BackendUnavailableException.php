<?php

namespace App\Exceptions;

use RuntimeException;

/** The Supabase database could not be reached or answered with an unexpected error. Details are logged, not shown. */
class BackendUnavailableException extends RuntimeException {}
