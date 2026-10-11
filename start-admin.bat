@echo off
REM ==========================================================================
REM  Melai Nuts - starts the ADMIN WEBSITE (Laravel) on http://127.0.0.1:8000
REM  First run also installs everything it needs. Keep this window open.
REM ==========================================================================
setlocal
cd /d "%~dp0admin"

where php >nul 2>nul || (echo [!] PHP not found. Install PHP 8.2+ ^(e.g. XAMPP^) and add it to PATH. See README "How to open the admin website". & pause & exit /b 1)
where composer >nul 2>nul || (echo [!] Composer not found. Install it from https://getcomposer.org/Composer-Setup.exe then open a NEW terminal. & pause & exit /b 1)

if not exist vendor\autoload.php (
  echo [setup] composer install ...
  call composer install --no-interaction || (pause & exit /b 1)
)
if not exist .env (
  echo [setup] creating .env ...
  copy .env.example .env >nul
  call php artisan key:generate
  if not exist database\database.sqlite type nul > database\database.sqlite
  echo.
  echo [!] Open admin\.env and fill in ADMIN_EMAIL, ADMIN_PASSWORD, FIREBASE_WEB_API_KEY and SUPABASE_DB_*
  echo     ^(the website only shows the app's real data; there is no demo mode^). Then run this file again.
  notepad .env
  pause
  exit /b 0
)
if not exist database\database.sqlite type nul > database\database.sqlite
call php artisan migrate --seed --force || (echo [!] Set ADMIN_EMAIL and ADMIN_PASSWORD in admin\.env first. & pause & exit /b 1)
REM Rebuild the page scripts/styles when they are missing OR older than resources\js / resources\css.
powershell -NoProfile -Command "$m=Get-Item public\build\manifest.json -ErrorAction SilentlyContinue; $n=(Get-ChildItem resources\js,resources\css -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime; if(-not $m -or $n -gt $m.LastWriteTime){exit 1}"
if errorlevel 1 (
  where npm >nul 2>nul || (echo [!] Node.js not found. Install it from https://nodejs.org & pause & exit /b 1)
  echo [setup] building the page styles ...
  if not exist node_modules call npm install
  call npm run build
)

REM SPEED: cache config, routes, views and events (saves work on EVERY page load). Runs on every
REM start, so changes to .env still apply after restarting this window.
call php artisan optimize

REM SPEED: OPcache keeps the compiled PHP in memory. Without it every page re-reads ~1000 PHP files.
php -r "exit(function_exists('opcache_get_status') && ini_get('opcache.enable') ? 0 : 1);" || (
  echo.
  echo [!] PHP OPcache is OFF - every page will be slower. To turn it on, open your php.ini
  echo     ^(run: php --ini^) and set:   zend_extension=opcache   opcache.enable=1   opcache.enable_cli=1
  echo.
)

echo.
echo  Admin website: http://127.0.0.1:8000   ^(close this window or press Ctrl+C to stop^)
echo.
start "" http://127.0.0.1:8000
php artisan serve --host=127.0.0.1 --port=8000