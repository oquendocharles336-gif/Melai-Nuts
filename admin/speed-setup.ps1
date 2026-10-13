# =============================================================================
# Melai Nuts admin - one-time speed setup for Windows (XAMPP PHP).
#   1. Turns on PHP OPcache in your php.ini (a backup copy is saved next to it first)
#   2. Adds a Windows Defender exclusion for the project folder (only when run as Administrator)
#   3. Rebuilds Laravel's caches so the new .env values are used
#
# Run it from the admin folder:
#   powershell -ExecutionPolicy Bypass -File .\speed-setup.ps1
# For step 2, open PowerShell with "Run as administrator" (otherwise step 2 is skipped).
# Afterwards: stop `php artisan serve` (Ctrl+C) and start it again.
# =============================================================================
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Step($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

# ---- 1. OPcache -------------------------------------------------------------------------------
Step 'PHP OPcache'
$ini = (& php -r 'echo php_ini_loaded_file();').Trim()
if (-not $ini -or -not (Test-Path $ini)) { throw 'No php.ini is loaded. Run "php --ini" to see where PHP looks for it.' }
Write-Host "php.ini: $ini"

$extDir = (& php -r 'echo ini_get(''extension_dir'');').Trim()
if (-not [IO.Path]::IsPathRooted($extDir)) { $extDir = Join-Path (Split-Path (Get-Command php).Source) $extDir }
if (-not (Test-Path (Join-Path $extDir 'php_opcache.dll'))) {
    Write-Host "php_opcache.dll was not found in $extDir - OPcache cannot be turned on with this PHP." -ForegroundColor Yellow
} else {
    $backup = "$ini.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $ini $backup
    Write-Host "Backup:  $backup"

    $text = [IO.File]::ReadAllText($ini)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]($text -split "`r?`n")

    # zend_extension=opcache: keep an active line, else uncomment one, else add one
    $active = $lines | Where-Object { $_ -match '^\s*zend_extension\s*=\s*"?(php_)?opcache(\.dll)?"?\s*$' }
    if (-not $active) {
        $i = 0; $done = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*;\s*zend_extension\s*=\s*"?(php_)?opcache(\.dll)?"?\s*$') { $lines[$i] = 'zend_extension=opcache'; $done = $true; break }
        }
        if (-not $done) { $lines.Add(''); $lines.Add('[opcache]'); $lines.Add('zend_extension=opcache') }
    }

    $settings = [ordered]@{
        'opcache.enable' = '1'; 'opcache.enable_cli' = '0'; 'opcache.memory_consumption' = '256';
        'opcache.interned_strings_buffer' = '16'; 'opcache.max_accelerated_files' = '20000';
        'opcache.validate_timestamps' = '1'; 'opcache.revalidate_freq' = '2'; 'realpath_cache_size' = '4096K';
        'realpath_cache_ttl' = '600'
    }
    foreach ($key in $settings.Keys) {
        $pattern = '^\s*;?\s*' + [regex]::Escape($key) + '\s*='
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                if (-not $found) { $lines[$i] = "$key=$($settings[$key])"; $found = $true }
                elseif ($lines[$i] -notmatch '^\s*;') { $lines[$i] = ";$($lines[$i])" }   # a second active copy would win
            }
        }
        if (-not $found) { $lines.Add("$key=$($settings[$key])") }
    }
    [IO.File]::WriteAllText($ini, ($lines -join $nl))

    $ok = (& php -r 'echo function_exists(''opcache_get_status'') ? ''yes'' : ''no'';').Trim()
    if ($ok -eq 'yes') { Write-Host 'OPcache is ON (it takes effect after you restart php artisan serve).' -ForegroundColor Green }
    else { Write-Host "OPcache did not load. Your original php.ini is saved as $backup." -ForegroundColor Yellow }
}

# ---- 2. Windows Defender exclusion ---------------------------------------------------------------
Step 'Windows Defender'
$project = Split-Path $PSScriptRoot -Parent
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    try {
        $phpDir = Split-Path (Get-Command php).Source
        Add-MpPreference -ExclusionPath $project, $phpDir
        Add-MpPreference -ExclusionProcess 'php.exe'
        Write-Host "Excluded from scanning: $project, $phpDir and php.exe" -ForegroundColor Green
    } catch { Write-Host "Could not add the exclusion: $($_.Exception.Message)" -ForegroundColor Yellow }
} else {
    Write-Host 'Skipped: run this script in PowerShell opened with "Run as administrator" to add it.' -ForegroundColor Yellow
}
if ($project -match 'OneDrive') { Write-Host 'The project is inside OneDrive: move it to e.g. C:\dev for speed.' -ForegroundColor Yellow }

# ---- 3. Laravel caches ------------------------------------------------------------------------------
Step 'Laravel caches'
& php artisan optimize:clear
& php artisan cache:clear
& php artisan optimize

Step 'Done'
Write-Host 'Now stop php artisan serve (Ctrl+C) and start it again, then run: php artisan melai:doctor'
