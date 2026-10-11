<?php

namespace App\Exceptions;

use RuntimeException;

/** The signed-in admin-portal user is not linked to a registered staff/owner account in Supabase. */
class StaffNotLinkedException extends RuntimeException {}
