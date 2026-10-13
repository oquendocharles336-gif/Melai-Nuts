<?php

namespace App\Database;

use Illuminate\Database\Connectors\PostgresConnector;

/**
 * Laravel's Postgres connector plus libpq TCP keepalives for connections whose config sets
 * 'keepalives_idle' (> 0): only the 'supabase' connection does (config/database.php).
 *
 * Why: the Supabase connection is kept open between page loads (PDO::ATTR_PERSISTENT). If a home
 * router / ISP NAT or the pooler drops it silently while idle, the next query would wait for the
 * operating system's TCP retransmission timeout (about 21 s on Windows) before Laravel reconnects.
 * With keepalives the dead connection is detected while idle and the next page reconnects at once.
 * pdo_pgsql hands these key=value pairs to libpq unchanged.
 */
class PostgresKeepaliveConnector extends PostgresConnector
{
    protected function getDsn(array $config)
    {
        $dsn = parent::getDsn($config);
        $idle = (int) ($config['keepalives_idle'] ?? 0);
        if ($idle > 0) {
            $dsn .= ';keepalives=1;keepalives_idle='.$idle
                .';keepalives_interval='.max(1, (int) ($config['keepalives_interval'] ?? 10));
        }

        return $dsn;
    }
}
